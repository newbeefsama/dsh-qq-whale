# watchdog.ps1 —— 常驻看护进程（单例）。
#
# 设计要点：
#
# 1) 为什么是常驻而不是「每次触发跑一遍」：
#    Task Scheduler 在用户会话里拉起控制台程序时，窗口会先生成再隐藏，
#    屏幕上会闪一下。原本用 wscript + WScript.Shell.Run(..., 0, False) 绕开，
#    但这台机器实测 WScript.Shell.Run 是坏的（能写文件，起不了进程）。
#    所以改成：任务只启动这一个进程，它在内部循环。
#
# 2) 为什么自己管单例：
#    实测 Task Scheduler 有时会「认为前一个实例已结束」而再起一个
#    （2026-10-22 11:00 和 12:00 各起了一个 watchdog，两个都在跑）。
#    所以启动时主动清掉其它 watchdog，不依赖 Task Scheduler 的 IgnoreNew。
#    过滤条件必须严格匹配 -File ...watchdog.ps1 结尾：
#    用过宽松的 *watchdog.ps1*，结果把命令行里提到这个文件名的排查 shell 也杀了。
#
# 3) 为什么守夜也在这里做：
#    原来 recover.ps1 会另起 keepawake.ps1 保持系统唤醒，结果和 watchdog 一样
#    经常跑成两份。现在由本进程直接持有执行状态请求（每个循环重新声明一次）。
#    必须带 ES_DISPLAY_REQUIRED：这台机器是 Modern Standby，
#    「熄屏 = 进待机」实测过（去掉 DISPLAY 后 22:12、22:23 两次 Idle Timeout）。

$ErrorActionPreference = 'Continue'

$root  = 'C:\path\to\deepseek-harness\default-workspace\qq群聊助手'
$tools = Join-Path $root '_工具'
$log   = Join-Path $tools '_watchdog.log'
$recover = Join-Path $tools 'recover.ps1'
$syncShared = Join-Path $tools 'sync-shared-memory.cjs'
$autoRotate = Join-Path $tools 'auto-rotate.cjs'
$nodeExe = 'D:\Node.js\node.exe'

function WLog($m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
  Write-Host $line
}

function TrimLog {
  try {
    if (Test-Path $log) {
      $lines = Get-Content $log -Encoding UTF8
      if ($lines.Count -gt 1000) { $lines | Select-Object -Last 500 | Set-Content $log -Encoding UTF8 }
    }
  } catch {}
}

# ---------- 单例：清掉其它 watchdog ----------
$me = $PID
$others = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object {
    $_.ProcessId -ne $me -and
    $_.CommandLine -and
    $_.CommandLine -match '-File\s+"?[^"]*watchdog\.ps1"?\s*$'
  })
foreach ($p in $others) {
  try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; WLog "清掉重复的 watchdog（PID $($p.ProcessId)）" } catch {}
}
if ($others.Count -gt 0) { Start-Sleep -Seconds 2 }

WLog "看护进程启动（PID $me），单例检查清掉 $($others.Count) 个"

# ---------- 执行状态请求（替代独立的 keepawake 进程）----------
# 注意类型：ES_CONTINUOUS = 0x80000000 在 PowerShell 里是 Int64，
# 直接 -bor 出来是负数，传给 UInt32 参数会报「值对于 UInt32 太大或太小」。
#   0x80000000 = ES_CONTINUOUS
#   0x00000001 = ES_SYSTEM_REQUIRED
#   0x00000002 = ES_DISPLAY_REQUIRED
#   合起来     = 0x80000003
$awakeFlags = [uint32]0x80000003

$awakeOk = $false
try {
  Add-Type -Namespace Win32 -Name WatchdogPower -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@ -ErrorAction Stop
  $r = [Win32.WatchdogPower]::SetThreadExecutionState($awakeFlags)
  $awakeOk = ($r -ne 0)
  if ($awakeOk) { WLog '  已声明保持唤醒（系统 + 显示）' } else { WLog '  SetThreadExecutionState 返回 0' }
} catch {
  WLog ("  Add-Type 失败，守夜功能不可用: " + $_.Exception.Message)
}

$i = 0
while ($true) {
  $i++

  # 每轮重新声明一次，防止被其它电源策略覆盖
  if ($awakeOk) { try { [void][Win32.WatchdogPower]::SetThreadExecutionState($awakeFlags) } catch {} }

  # 每 2 分钟：跑一次服务恢复
  try {
    & $recover 6>&1 | Out-Null
  } catch {
    WLog ("recover.ps1 执行出错: " + $_.Exception.Message)
  }

  # 每 5 轮（约 10 分钟）：检查会话是否跑太多轮了，超了就轮换
  # 背景：群会话跑到 38 轮时上下文涨到 37 万 token，之后的回合只输出 step1 就
  # 再没下文（怎么叫都不说话）。轮换会保留记忆和唤醒配置，并留一份交接摘要给新会话。
  if ($i % 5 -eq 0) {
    try {
      # 注意括号：Test-Path 只接受路径，不能把 -and 塞进它的参数里
      # （写成 `Test-Path $a -and (Test-Path $b)` 会报「找不到与参数名称"and"匹配的参数」，
      #   昨晚实测这行每 10 分钟失败一次，自动轮换等于一直没生效）
      if ((Test-Path $nodeExe) -and (Test-Path $autoRotate)) {
        $out = & $nodeExe $autoRotate 2>&1
        # 只有真轮换了才写日志，避免每 10 分钟刷一行"无需轮换"
        if ($out -match '已轮换') { WLog ('  自动轮换: ' + (($out | Where-Object { $_ -match '已轮换' }) -join ' | ')) }
      } else {
        WLog '  自动轮换跳过：node 或脚本不存在'
      }
    } catch {
      WLog ('  自动轮换检查失败: ' + $_.Exception.Message)
    }
  }

  # 每 30 轮（约 1 小时）：同步跨会话共享记忆
  # 桥接是「一个 QQ 会话 = 一个独立 DSH 会话」，记忆天然隔离；
  # 这段把各私聊的近况写进人格卡，而人格卡每条消息都会注入。
  if ($i % 30 -eq 0) {
    try {
      if (Test-Path $nodeExe) {
        & $nodeExe $syncShared 2>&1 | Out-Null
        WLog '  已同步跨会话共享记忆'
      }
    } catch {
      WLog ('  共享记忆同步失败: ' + $_.Exception.Message)
    }
  }

  # 每 60 轮（约 2 小时）：心跳 + 日志裁剪
  if ($i % 60 -eq 0) {
    WLog "看护心跳：第 $i 轮"
    TrimLog
  }

  Start-Sleep -Seconds 120
}
