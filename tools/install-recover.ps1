# 安装自动恢复计划任务（必须以管理员身份运行）
#
# 触发：
#   1. 每 2 分钟一次（保底）
#   2. 系统从睡眠/休眠恢复时（Kernel-Power 事件 107）—— 今天定位到的主要死因
#
# 主体：当前用户 + RunLevel Highest。实测这条组合 IsAdmin = True，
# 所以能提权启动 SnowLuma（它必须提权才能 hook QQ）。
# 之前误判成"任务不提权"是错的，别再踩。
#
# 删除：Unregister-ScheduledTask -TaskName 'BotAutoRecover' -Confirm:$false

$ErrorActionPreference = 'Continue'

$root  = 'C:\path\to\deepseek-harness\default-workspace\qq群聊助手'
$tools = Join-Path $root '_工具'
$script = Join-Path $tools 'recover.ps1'
$task   = 'BotAutoRecover'
$log    = Join-Path $tools '_install-recover.log'

function Note($m) {
  $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  Write-Host $line
  try { Add-Content -Path $log -Value $line -Encoding UTF8 } catch {}
}

Note '=== 安装自动恢复任务 ==='

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Note '不是管理员，退出'; exit 2 }
if (-not (Test-Path $script)) { Note "找不到 $script"; exit 3 }

# --- 触发 1：每 2 分钟 ---
$trigTime = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
  -RepetitionInterval (New-TimeSpan -Minutes 2) `
  -RepetitionDuration (New-TimeSpan -Days 3650)

# --- 触发 2：从睡眠/休眠恢复（Kernel-Power 107）---
$eventTrigger = $null
try {
  $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
  $eventTrigger = New-CimInstance -CimClass $class -ClientOnly
  $eventTrigger.Enabled = $true
  # 107 = 系统已从睡眠状态恢复
  $eventTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]</Select></Query></EventSubscription>' -replace 'EventSubscription>', 'QueryList>'
  $eventTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]</Select></Query></QueryList>'
  Note '事件触发器创建成功（恢复自睡眠）'
} catch {
  Note ("事件触发器创建失败，只用定时触发: " + $_.Exception.Message)
  $eventTrigger = $null
}

$triggers = @($trigTime)
if ($eventTrigger) { $triggers += $eventTrigger }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

$principal = New-ScheduledTaskPrincipal -UserId (whoami) -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries `
  -StartWhenAvailable `
  -MultipleInstances IgnoreNew `
  -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

try { Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction Stop; Note '旧任务已删除' } catch {}
try {
  Register-ScheduledTask -TaskName $task `
    -Description '每2分钟+睡眠恢复时检查 SnowLuma(3000)/Tulpa(18777)，掉了自动拉起。管理员权限。' `
    -Action $action -Trigger $triggers -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
  Note '注册成功'
} catch { Note ('注册失败: ' + $_.Exception.Message); exit 8 }

Start-Sleep -Seconds 1
$tk = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
if ($tk) {
  Note ("校验: State=" + $tk.State + " RunLevel=" + $tk.Principal.RunLevel + " 触发器数=" + $tk.Triggers.Count)
  Start-ScheduledTask -TaskName $task
  Start-Sleep -Seconds 3
  $i = $tk | Get-ScheduledTaskInfo
  Note ("已试跑一次: LastRun=" + $i.LastRunTime + " Result=" + $i.LastTaskResult)
} else { Note '校验失败：任务查不到'; exit 9 }

Note '=== 完成 ==='
