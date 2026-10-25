# Elevated restart of SnowLuma with stdout/stderr captured to files,
# so the hook failure is visible instead of being swallowed.
$ErrorActionPreference = 'Continue'

$root = 'C:\path\to\deepseek-harness\default-workspace\qq群聊助手'
$snow = Join-Path $root 'SnowLuma'
$tools = Join-Path $root '_工具'
$outLog = Join-Path $tools '_snow-console.out.log'
$errLog = Join-Path $tools '_snow-console.err.log'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Host "elevated = $isAdmin"
if (-not $isAdmin) { exit 2 }

Write-Host '--- stopping old SnowLuma ---'
Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -like '*SnowLuma*index.mjs*' } |
  ForEach-Object { Write-Host "  stop PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 4

Remove-Item $outLog, $errLog -Force -ErrorAction SilentlyContinue

Write-Host '--- starting SnowLuma (captured) ---'
$p = Start-Process -FilePath (Join-Path $snow 'node.exe') `
  -ArgumentList (Join-Path $snow 'index.mjs') `
  -WorkingDirectory $snow `
  -RedirectStandardOutput $outLog `
  -RedirectStandardError $errLog `
  -PassThru
Write-Host "  PID = $($p.Id)"

Start-Sleep -Seconds 8
Write-Host '--- early stdout ---'
if (Test-Path $outLog) { Get-Content $outLog -Encoding UTF8 -Tail 20 | ForEach-Object { Write-Host "  $_" } }
Write-Host '--- early stderr ---'
if (Test-Path $errLog) { Get-Content $errLog -Encoding UTF8 -Tail 30 | ForEach-Object { Write-Host "  $_" } }
Write-Host '--- done ---'
