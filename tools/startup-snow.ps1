# 开机/登录时自动请求提权启动 SnowLuma。
#
# 为什么需要它：实测（2026-10-25 两组对照）
#   - 由计划任务上下文启动的 SnowLuma：/api/processes 扫到 0 个 QQ，永远 hook 不上
#   - 由 UAC（consent.exe）启动的 SnowLuma：3 秒内 hook 成功
#     两者都是管理员、都在会话 2，唯一差别是令牌来源。
# 所以自动开机只能走「弹一次 UAC」这条路 —— 弹窗由 explorer 拉起本脚本触发，
# 用户点一次「是」之后进入的就是能正常 hook 的上下文。
#
# 行为：
#   1. 如果 3000 已经通了（看护刚好成功了），直接退出，不打扰
#   2. 否则请求提权启动 snow-elevated.ps1
#   3. 全程写日志到 _startup-snow.log

$ErrorActionPreference = 'Continue'
$root  = 'C:\path\to\deepseek-harness\default-workspace\qq群聊助手'
$tools = Join-Path $root '_工具'
$log   = Join-Path $tools '_startup-snow.log'

function T($m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

T '=== 开机 SnowLuma 启动器 ==='

# 等网络/桌面就绪一会儿，避免抢在 explorer 前面
Start-Sleep -Seconds 20

# 已经通了就别弹窗
$up = Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue
if ($up) {
  T '  3000 已监听，无需处理'
  exit 0
}

# QQ 不在就先不弹（没有注入目标）
$qq = @(Get-Process -Name QQ -ErrorAction SilentlyContinue).Count
if ($qq -eq 0) {
  T '  QQ 未运行，跳过（等 QQ 起来后看护会再试，或下次登录）'
  exit 0
}
T ("  QQ 进程数: " + $qq)

# 别和看护抢：如果 15 分钟内刚失败过，说明看护正在处理，等下一轮
$fail = Join-Path $tools '_snow-fail.flag'
if (Test-Path $fail) {
  try {
    $age = ((Get-Date) - [datetime]::Parse((Get-Content $fail -Raw -Encoding UTF8).Trim())).TotalMinutes
    if ($age -lt 5) {
      T ("  看护 " + [math]::Round($age) + " 分钟前刚试过，跳过本轮")
      exit 0
    }
  } catch {}
}

# 请求提权
$elevated = Join-Path $tools 'snow-elevated.ps1'
if (-not (Test-Path $elevated)) {
  T ("  找不到 " + $elevated)
  exit 1
}

T '  请求提权启动 SnowLuma（会弹 UAC）'
try {
  $p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $elevated `
    -Verb RunAs -PassThru -ErrorAction Stop
  T ("  已提权启动 PID " + $p.Id)
  $p | Wait-Process -Timeout 120 -ErrorAction SilentlyContinue
} catch {
  T ("  提权失败（可能用户点了取消）: " + $_.Exception.Message)
  exit 1
}

# 验证
$ok = $false
for ($i = 0; $i -lt 12; $i++) {
  Start-Sleep -Seconds 5
  if (Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue) { $ok = $true; break }
}
if ($ok) { T '  ✅ SnowLuma 已恢复（3000 监听中）' }
else { T '  ❌ 仍未监听，请手动检查' }
T '=== 结束 ==='
