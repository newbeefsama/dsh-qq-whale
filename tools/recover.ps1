# 自动恢复脚本：检查端口，哪个服务掉了就拉起来。
#
# 以计划任务身份运行（RunLevel Highest + LogonType Interactive）→ 实测 IsAdmin = True，
# 所以能提权启动 SnowLuma（SnowLuma 必须提权才能 hook QQ）。
#
# 触发时机：
#   1. 每 2 分钟一次（保底）
#   2. 系统从睡眠/休眠恢复时（事件 Kernel-Power 107）——这是今天定位到的真正死因

$ErrorActionPreference = 'Continue'

$root  = 'C:\Users\<你>\Documents\deepseek-harness\default-workspace\qq群聊助手'
$tools = Join-Path $root '_工具'
$snow  = Join-Path $root 'SnowLuma'
$tulpa = Join-Path $root 'Tulpa'
$log   = Join-Path $tools '_recover.log'

# 启动标记：用来区分「计划任务根本没跑脚本」和「脚本跑到一半挂了」。
# 之前排查过：任务 Result=0 但日志一行没有 —— 因为 wscript 用 Run(...,0,False) 不等待，
# wscript 自己立刻返回 0，所以 Result=0 什么都不能证明。
$script:StartMark = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  [启动] recover.ps1 开始执行（PID $PID）"
try { Add-Content -Path $log -Value $script:StartMark -Encoding UTF8 } catch {}

function Note($m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

function PortUp($port) {
  $c = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  return [bool]$c
}

# SnowLuma 注入体检查（2026-10-24 加）
#
# 为什么需要：SnowLuma 的 hook 是「扫一遍 QQ 进程再注入」。它**必须提权**才能扫到。
# 不提权时它不报错 —— 只打印一行 "hook auto-load enabled"，然后什么都不做，
# WebUI 起来了、5099 在听，只有 3000/3001 永远不通。
# 今天就是被这个静默失败卡了一个多小时，只能靠重启 DSH/QQ/整机瞎试。
#
# 这里在 3000 起不来时，直接问 SnowLuma 自己的 /api/processes：
#   扫到 QQ 且 injected=true  → hook 成功
#   扫到 QQ 但 injected=false → 注入被拒
#   一个都没扫到              → 几乎肯定是没提权（或 QQ 没开）
function NoteSnowLumaHookState {
  try {
    $pwFile = Join-Path $tools '_snow-webui-pw.txt'
    $pw = 'Whale2026QQ'
    if (Test-Path $pwFile) {
      $saved = (Get-Content $pwFile -Raw -Encoding UTF8).Trim()
      if ($saved) { $pw = $saved }
    }
    $login = Invoke-RestMethod -Uri 'http://127.0.0.1:5099/api/login' -Method Post `
      -ContentType 'application/json' -Body (@{ password = $pw } | ConvertTo-Json) -TimeoutSec 15
    if (-not $login.token) { Note '    （注入体检查：WebUI 登录没拿到 token，跳过）'; return }
    $hdr = @{ Authorization = 'Bearer ' + $login.token }
    $procs = Invoke-RestMethod -Uri 'http://127.0.0.1:5099/api/processes' -Headers $hdr -TimeoutSec 15
    $list = @($procs.list)
    if ($list.Count -eq 0) {
      Note '    注入体检查：SnowLuma 扫到 0 个 QQ 进程 —— 多半是没提权（或 QQ 没开）'
      return
    }
    foreach ($p in $list) {
      Note ("    注入体检查：QQ PID " + $p.pid + "  injected=" + $p.injected + "  connected=" + $p.connected + "  loggedIn=" + $p.loggedIn + "  uin=" + $p.uin + "  status=" + $p.status)
    }
    if (-not ($list | Where-Object { $_.injected -eq $true })) {
      Note '    注入体检查：扫到了 QQ 但 injected 全是 false —— 注入被拒（可能被安全软件拦了）'
    }
  } catch {
    Note ("    注入体检查失败：" + $_.Exception.Message)
  }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# 日志只保留最近 2000 行，别让它无限长大
try {
  if (Test-Path $log) {
    $lines = Get-Content $log -Encoding UTF8
    if ($lines.Count -gt 2000) {
      $lines | Select-Object -Last 1000 | Set-Content $log -Encoding UTF8
    }
  }
} catch {}

# ---------- DSH 重启信号（2026-10-24 加）----------
# 为什么需要：MCP 工具列表在 DSH 启动时加载一次，桥接新增工具后必须重启 DSH 才可见。
# 但 DSH 是这个 workspace 里所有东西的父进程 —— 从会话内部杀掉自己就再也起不来了。
# 所以走信号文件：我在会话里丢一个 _restart-dsh.flag，由看护（独立进程）代劳。
$dshFlag = Join-Path $tools '_restart-dsh.flag'
if (Test-Path $dshFlag) {
  Remove-Item $dshFlag -Force -ErrorAction SilentlyContinue
  Note '发现 DSH 重启信号，准备重启 DSH'
  $dshExe = 'D:\deepseek harness\DeepSeek Harness.exe'
  if (-not (Test-Path $dshExe)) {
    Note ("  DSH 可执行文件不存在: " + $dshExe)
  } else {
    # 1) 先停桥接（它依赖 DSH，留着会一直报连不上）
    $b = Get-NetTCPConnection -LocalPort 3100 -State Listen -ErrorAction SilentlyContinue
    if ($b) { try { Stop-Process -Id $b.OwningProcess -Force -ErrorAction Stop; Note '  已停桥接' } catch {} }
    # 2) 杀掉所有 DSH 进程（含 GPU/renderer 子进程）
    $killed = 0
    Get-Process | Where-Object { $_.ProcessName -like '*DeepSeek*' } | ForEach-Object {
      try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $killed++ } catch {}
    }
    Note ("  已停止 DSH 进程 " + $killed + " 个")
    Start-Sleep -Seconds 6
    # 3) 重新拉起（主窗口）
    try {
      Start-Process -FilePath $dshExe -WorkingDirectory (Split-Path $dshExe -Parent)
      Note '  DSH 已重新启动（等它自己开端口，下一轮 recover 会跟端口并拉起桥接）'
    } catch { Note ("  DSH 重启失败: " + $_.Exception.Message) }
    # 这一轮不再往下走：DSH 正在启动，端口还没出来
    return
  }
}

# ---------- qq-bridge（3100）：现在群里说话的其实是它 ----------
# 2026-10-21 起，群聊由 qq-bridge 唤醒 DSH agent 来说。它有两件事自己管不了：
#
#   1. DSH Web 端口每次启动都会变（62300 -> 54315 -> ...），而桥接的 config.json
#      里写死了 baseUrl。不跟着改，DSH 一重启桥接就连不上，而且它自己不会改。
#   2. 桥接进程崩了没人管（我是用 Start-Process 裸起的，没有守护）。
#      这里改用 start.bat 的守护循环（崩溃 5 秒自启），经 VBS 无窗拉起。
$bridgeDir = 'C:\Users\<你>\Documents\deepseek-harness\default-workspace\qq-bridge'
$bridgeCfg = Join-Path $bridgeDir 'config.json'

# --- 1. 让 baseUrl 跟随 DSH 实际端口 ---
# 注意：这里要选**最新的**那个 DSH 进程的端口。
# 原来写的是 Sort-Object -Unique | Select-Object -First 1，也就是取最小端口号 ——
# 新旧两个 DSH 实例同时在跑时会选错。
$dshPort = $null
try {
  $dshPort = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like '*DeepSeek*') {
      [pscustomobject]@{ Port = $_.LocalPort; Started = $p.StartTime }
    }
  } | Sort-Object Started -Descending | Select-Object -First 1 -ExpandProperty Port
} catch {}

if ($dshPort -and (Test-Path $bridgeCfg)) {
  try {
    $raw = Get-Content $bridgeCfg -Raw -Encoding UTF8
    if ($raw -match '"baseUrl":\s*"http://127\.0\.0\.1:(\d+)"') {
      $oldPort = $matches[1]
      if ($oldPort -ne "$dshPort") {
        $newRaw = $raw -replace '("baseUrl":\s*"http://127\.0\.0\.1:)\d+(")', "`${1}$dshPort`${2}"
        [System.IO.File]::WriteAllText($bridgeCfg, $newRaw, (New-Object System.Text.UTF8Encoding($false)))
        Note "桥接 baseUrl 跟随 DSH 端口：$oldPort -> $dshPort（要重启桥接才生效）"
        $bc = Get-NetTCPConnection -LocalPort 3100 -State Listen -ErrorAction SilentlyContinue
        if ($bc) {
          try { Stop-Process -Id $bc.OwningProcess -Force -ErrorAction Stop; Note '  已停旧桥接，准备用新端口重启' } catch {}
          Start-Sleep -Seconds 3
        }
      }
    }
  } catch { Note ("  改写桥接 baseUrl 失败: " + $_.Exception.Message) }
}

# --- 2. 桥接在不在，不在就拉起来 ---
# 不用 start.bat 的守护循环了：试过 wscript -> cmd -> start.bat 那条路，
# 中文路径 + 嵌套引号转义太脆，实测起不来。
# 反正 recover.ps1 本来就每 2 分钟跑一次 —— 它本身就是守护者：崩了最多 2 分钟被拉起。
# 注意：桥接的命令行是相对路径 `src/bridge.js`，别用 *qq-bridge\src\bridge.js* 过滤。
#
# 手动重启桥接的办法（不需要 UAC）：
#   桥接是提权进程，普通权限 kill 不掉。但本脚本以管理员身份运行，
#   所以只要丢一个信号文件 _restart-bridge.flag，下一轮（最多 2 分钟）就会重启它。
$restartFlag = Join-Path $tools '_restart-bridge.flag'
if (Test-Path $restartFlag) {
  Note '发现桥接重启信号，重启桥接中'
  $conn3100 = Get-NetTCPConnection -LocalPort 3100 -State Listen -ErrorAction SilentlyContinue
  if ($conn3100) {
    try { Stop-Process -Id $conn3100.OwningProcess -Force -ErrorAction Stop; Note "  已停旧桥接 PID $($conn3100.OwningProcess)" } catch { Note ("  停旧桥接失败: " + $_.Exception.Message) }
    Start-Sleep -Seconds 3
  }
  Remove-Item $restartFlag -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $bridgeDir 'state\bridge.lock') -Force -ErrorAction SilentlyContinue
}

$bridgeProc = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*bridge*' -and $_.CommandLine -notlike '*mcp-*' }

# ── DSH 没起就别起桥接（2026-10-24 加）──────────────────────────────
# 事故：今早 09:38:20 recover 先跑、DSH 09:38:57 才起。那次检测不到 DSH 端口，
# 于是用 config 里的旧端口（52986）把桥接拉起来了 —— 桥接连的是已经不存在的端口，
# 用户看到的就是「连接失败」。而它自己不会改端口，只能等下一轮 recover 修。
# 所以：DSH 不在时直接跳过，等 DSH 起来后再拉桥接（那时 baseUrl 也已经跟上了）。
if (-not $dshPort) {
  if (PortUp 3100) {
    Note 'DSH 不在，但桥接在跑 —— 保留，等 DSH 起来'
  } else {
    Note 'DSH 不在（没有 DeepSeek 进程监听），暂不启动桥接'
  }
} elseif (-not (PortUp 3100) -and -not $bridgeProc) {
  Note '桥接不在（3100 未监听且无进程），拉起'
  try {
    Remove-Item (Join-Path $bridgeDir 'state\bridge.lock') -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath 'D:\Node.js\node.exe' `
      -ArgumentList 'src/bridge.js' `
      -WorkingDirectory $bridgeDir `
      -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $bridgeDir 'logs\bridge-out.log') `
      -RedirectStandardError  (Join-Path $bridgeDir 'logs\bridge-err.log')
    Start-Sleep -Seconds 16
    if (PortUp 3100) { Note '  桥接恢复成功' } else { Note '  桥接启动后仍未监听' }
  } catch { Note ("  桥接拉起失败: " + $_.Exception.Message) }
}

# ---------- 自动加好友（2026-10-26 起停用）----------
# 原来这里常驻拉起 friend-accept.cjs，策略是「好友申请一律同意 + 无条件加白名单」——
# 那是个无差别门童，AI 完全没参与。现在改成桥接内建：收到申请先落盘、私聊通知 owner，
# 等 AI 下次唤醒时用 qq_friend_requests / qq_accept_friend 自己判断。
# 所以这里不再拉起任何脚本。若你手动跑过 friend-accept.cjs，记得关掉它，
# 否则它会和桥接抢同一批事件、抢先自动同意。
# ---------- 戳一戳实时监听：已停用 ----------
# 2026-10-22 停用 poke-live.cjs。原因：它的逻辑是「被戳 → 戳回去，不插话」，
# 那是早期没有桥接时的应急方案。现在桥接自己处理 poke 事件并唤醒 AI 说话，
# poke-live 在前头把戳接住、只戳回去不说话，反而让 AI 表现为"被戳了没反应"。
# 如果还发现残留进程，顺手清掉。
$pl = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*poke-live.cjs*' }
foreach ($p in $pl) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Note "清掉过时的 poke-live（PID $($p.ProcessId)）" } catch {}
}

# ---------- 守夜：已并入 watchdog.ps1 ----------
# 2026-10-22 起不再单独起 keepawake.ps1 进程。
# 原因：watchdog 和 keepawake 各自都可能被拉起两份（实测 11:00 和 12:00 各多一个），
# 两个常驻进程互相看不见对方的存在，重复启动无法收敛。
# 现在由 watchdog.ps1 自己持有 ES_SYSTEM_REQUIRED|ES_DISPLAY_REQUIRED，少一个进程。
#
# 历史结论（保留备查）：这台机器是 Modern Standby，「熄屏 = 进待机」。
#   16:36-22:04 带 DISPLAY（屏幕常亮）→ 零次 Idle 待机
#   22:04   去掉 DISPLAY（允许熄屏）  → 22:12、22:23 两次 Idle Timeout 待机
#   所以必须让屏幕亮着。想「熄屏 + 运行」只能改注册表关掉 Modern Standby（有风险）。
#
# 如果发现残留的旧 keepawake 进程，这里顺手清掉，避免它继续抢显示状态。
$oldKa = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like '*keepawake*.ps1*' })
foreach ($p in $oldKa) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Note "清掉残留的 keepawake（PID $($p.ProcessId)）" } catch {}
}

# ---------- Tulpa（18777）----------
if (-not (PortUp 18777)) {
  Note "Tulpa 端口 18777 未监听，重启中"
  try {
    Start-Process -FilePath (Join-Path $tulpa 'runtime\python.exe') `
      -ArgumentList 'app_mcp.py' `
      -WorkingDirectory $tulpa `
      -WindowStyle Hidden
    Start-Sleep -Seconds 12
    if (PortUp 18777) { Note '  Tulpa 恢复成功' } else { Note '  Tulpa 启动后仍未监听' }
  } catch { Note ("  Tulpa 启动失败: " + $_.Exception.Message) }
}

# ---------- SnowLuma（3000）----------
if (-not (PortUp 3000)) {
  if (-not $isAdmin) {
    Note 'SnowLuma 掉了，但当前不是管理员，无法启动（需要提权 hook QQ）'
  } else {
    # 冷却：连续失败后拉长重试间隔，别每 2 分钟杀一次重启一次。
    # 反复杀 QQ 里的 hook 会让 QQ 侧状态变坏，重启就更难成功。
    $failFile = Join-Path $tools '_snow-fail.flag'
    $skip = $false
    if (Test-Path $failFile) {
      try {
        $last = [datetime]::Parse((Get-Content $failFile -Raw -Encoding UTF8).Trim())
        $age = ((Get-Date) - $last).TotalMinutes
        if ($age -lt 15) {
          $skip = $true
          Note ("SnowLuma 仍在故障中，冷却中（上次失败 " + [math]::Round($age) + " 分钟前），跳过")
        }
      } catch {}
    }

    if (-not $skip) {
      # ── 先确认 QQ 在跑（2026-10-23 加）──────────────────────────────
      # SnowLuma 的 hook 是「启动时扫一遍已存在的 QQ 进程」。
      # 开机顺序里如果 SnowLuma 比 QQ 先起来，它扫不到任何人 ——
      # 表现就是 5099 起来了但 3000/3001 始终不监听，看起来"hook 失败"。
      # 今早 09:45 就是这么失败的：QQ 还没起，SnowLuma 空转；
      # 等 09:46 QQ 起来后再手动重启一次，15 秒就 hook 上了。
      # 所以：QQ 不在就直接跳过，别浪费一次尝试（还会进 15 分钟冷却）。
      $qqAlive = @(Get-Process -Name QQ -ErrorAction SilentlyContinue).Count
      if ($qqAlive -eq 0) {
        Note 'SnowLuma 需要 hook QQ，但 QQ 进程不在 —— 跳过（等 QQ 起来再试）'
        $skip = $true
      }
    }

    if (-not $skip) {
      # ── 不再自己启动 SnowLuma（2026-10-25 改）──────────────────────
      #
      # 实测证据（两组对照实验，条件完全一致）：
      #   计划任务上下文启动 → /api/processes 扫到 0 个 QQ，3000 永不监听
      #   UAC（consent.exe）启动 → 3 秒内 hook 成功
      #   两者都是管理员、都在会话 2、都能用 CIM 枚举到 9 个 QQ 进程，
      #   唯一差别就是令牌来源 —— 注入器在计划任务的令牌下拿不到 QQ。
      #
      # 所以原来这里「自己 Start-Process」的结果是：起了一个 5099 能开、
      # 3000 永远不来的**半死实例**。那比不启动更糟 —— 看起来活着，实际谁都不回。
      #
      # 新策略：
      #   1. 这里只诊断 + 留一个待办标记，不动进程
      #   2. 开机由「启动文件夹」里的 startup-snow.ps1 弹 UAC 拉起（已验证可行）
      #   3. 运行期间真掉了，就留标记，人看到日志/标记后点一下桌面快捷方式
      Note 'SnowLuma 3000 未监听。计划任务上下文无法注入 QQ（实测），不再自动重启'
      NoteSnowLumaHookState
      try { (Get-Date).ToString('o') | Set-Content $failFile -Encoding UTF8 } catch {}
      $needUac = Join-Path $tools '_需要点UAC重启SnowLuma.flag'
      try { (Get-Date).ToString('o') | Set-Content $needUac -Encoding UTF8 } catch {}
      Note '  已留标记：_需要点UAC重启SnowLuma.flag（双击桌面「重启SNOW」即可）'
    }
  }
}

# 两个都在就什么都不写，避免日志刷屏
