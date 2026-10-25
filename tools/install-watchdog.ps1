# 注册 SnowLuma/Tulpa 看门狗计划任务（必须以管理员身份运行）
#
# 以 SYSTEM 账户运行，原因有两个：
#   1. SYSTEM 天然拥有完整权限 —— 当前用户即使属于管理员组，拿到的也是 UAC 降权令牌，
#      拉起的 SnowLuma 无法 hook QQ（实测：进程能起，端口起不来）。
#   2. SYSTEM 跑在 session 0，不会在用户桌面闪控制台窗口。
#
# 删除：Unregister-ScheduledTask -TaskName 'SnowLumaWatchdog' -Confirm:$false
#
# 本脚本会把过程写进 _install-watchdog.log，方便排查。

$ErrorActionPreference = 'Continue'

$root   = 'C:\path\to\deepseek-harness\default-workspace\qq群聊助手'
$tools  = Join-Path $root '_工具'
$wd     = Join-Path $tools 'snow-watchdog.ps1'
$task   = 'SnowLumaWatchdog'
$log    = Join-Path $tools '_install-watchdog.log'

function Note($m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  Write-Host $line
  try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

Note '=== 开始注册看门狗 ==='

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Note '不是管理员，退出'; exit 2 }
Note '管理员身份 OK'

if (-not (Test-Path $wd)) { Note "找不到看门狗脚本: $wd"; exit 3 }
Note "看门狗脚本存在: $wd"

try {
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wd`""
  Note '动作创建 OK'
} catch { Note ('动作创建失败: ' + $_.Exception.Message); exit 4 }

try {
  $triggerBoot = New-ScheduledTaskTrigger -AtStartup
  $triggerLoop = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 1) `
    -RepetitionDuration (New-TimeSpan -Days 3650)
  Note '触发器创建 OK'
} catch { Note ('触发器创建失败: ' + $_.Exception.Message); exit 5 }

try {
  $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  Note ('主体创建 OK: ' + $principal.UserId + ' / ' + $principal.LogonType + ' / ' + $principal.RunLevel)
} catch { Note ('主体创建失败: ' + $_.Exception.Message); exit 6 }

try {
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  Note '设置创建 OK'
} catch { Note ('设置创建失败: ' + $_.Exception.Message); exit 7 }

try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop; Note '旧任务已删除' }
catch { Note '没有旧任务，继续' }

try {
  Register-ScheduledTask -TaskName $task `
    -Description '每分钟检查 SnowLuma(3000) 与 Tulpa(18777)，掉了自动拉起。SYSTEM 权限。' `
    -Action $action -Trigger $triggerBoot, $triggerLoop `
    -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
  Note '注册成功'
} catch { Note ('注册失败: ' + $_.Exception.Message); exit 8 }

Start-Sleep -Seconds 1
$tk = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if ($tk) {
  Note ("校验: State=" + $tk.State + " UserId=" + $tk.Principal.UserId + " RunLevel=" + $tk.Principal.RunLevel)
  Start-ScheduledTask -TaskName $task
  Start-Sleep -Seconds 3
  $i = $tk | Get-ScheduledTaskInfo
  Note ("已触发一次: LastRun=" + $i.LastRunTime + " Result=" + $i.LastTaskResult)
} else {
  Note '校验失败：任务查不到'
  exit 9
}

Note '=== 完成 ==='
