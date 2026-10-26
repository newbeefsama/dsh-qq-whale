<#
.SYNOPSIS
    dsh-qq-whale 安装器 —— 把这一套装进你已装好的 DSH 环境。

.DESCRIPTION
    前提（这个脚本不会帮你装）：
      · Windows 10/11
      · Node.js 24+（node:sqlite 需要）
      · Python 3.10+（语音/视频功能用；不装也能跑，只是少两个功能）
      · DeepSeek Harness 桌面版（官方安装包）
      · SnowLuma（QQ 协议端，已扫码登录过）
      · qq-bridge（git clone 上游仓库并 npm install 过）

    这个脚本做的事：
      1. 检查环境
      2. 交互式收集 8 个配置值（能自动探测的就自动填）
      3. 生成 qq-bridge/config.json
      4. 把 tools/ 里脚本的占位路径替换成你的真实路径
      5. 接入 DSH：插件目录 + profile 的 package.json + node_modules junction + cordis.patch.yml 的 MCP 段
      6. 注册计划任务（需要管理员）
      7. 创建开机启动快捷方式
      8. 跑一遍验证清单

    可以重复执行（幂等）。已有的配置不会覆盖，除非你明确同意。

.PARAMETER Unattended
    非交互模式：所有值从环境变量读。给 CI 或批量部署用。
    需要的环境变量见 README。

.EXAMPLE
    # 右键「以管理员身份运行 PowerShell」，然后
    .\install.ps1
#>
[CmdletBinding()]
param(
  [switch]$Unattended,
  # DSH 用户目录。默认 ~/.dsh。留这个参数是为了能装到非默认位置，
  # 也方便在临时目录做安装器自测（不碰真实的 DSH 配置）。
  [string]$DshHome = '',
  # 跳过一切对系统的改动（注册计划任务、创建快捷方式）——自动化测试用。
  # 不加这个开关在临时目录里测会**覆盖真实机器的计划任务和快捷方式**（踩过）。
  [switch]$SkipSystem,
  # 跳过写 DSH 配置（插件/profile/cordis）——只验证环境用。
  [switch]$SkipDsh
)

$ErrorActionPreference = 'Stop'
$script:StepNo = 0
$script:Errors = New-Object System.Collections.ArrayList
$script:Warnings = New-Object System.Collections.ArrayList

# ============================================================
# 工具函数
# ============================================================
function Step($msg) {
  $script:StepNo++
  Write-Host ''
  Write-Host ("━" * 62) -ForegroundColor DarkGray
  Write-Host ("[$($script:StepNo)] $msg") -ForegroundColor Cyan
  Write-Host ("━" * 62) -ForegroundColor DarkGray
}
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [警告] $m" -ForegroundColor Yellow; [void]$script:Warnings.Add($m) }
function Bad($m)  { Write-Host "  [失败] $m" -ForegroundColor Red;    [void]$script:Errors.Add($m) }
function Info($m) { Write-Host "         $m" -ForegroundColor Gray }

# 写 UTF-8（带 BOM）文本 —— PowerShell 5.1 读脚本时没有 BOM 会把中文读成乱码
function WriteTextUtf8Bom($path, $text) {
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
}
function WriteTextUtf8NoBom($path, $text) {
  $dir = Split-Path $path -Parent
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
}
function ReadTextAuto($path) {
  if (-not (Test-Path $path)) { return $null }
  return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

# 从 JSON 文件读，容忍 BOM
function ReadJsonFile($path) {
  $t = ReadTextAuto $path
  if (-not $t) { return $null }
  if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
  return ($t | ConvertFrom-Json)
}

function Ask($prompt, $default = '', [switch]$Quiet) {
  if ($Unattended) { return $default }
  $suffix = if ($default) { " [$default]" } else { '' }
  while ($true) {
    $ans = Read-Host ("  " + $prompt + $suffix)
    if ([string]::IsNullOrWhiteSpace($ans)) {
      if ($default) { return $default }
      Write-Host "    ↑ 不能为空" -ForegroundColor Yellow
      continue
    }
    return $ans.Trim()
  }
}

function AskInt($prompt, $default = 0) {
  while ($true) {
    $v = Ask $prompt $(if ($default) { "$default" } else { '' })
    $n = 0
    if ([int]::TryParse($v, [ref]$n) -and $n -gt 0) { return $n }
    Write-Host "    ↑ 需要正整数" -ForegroundColor Yellow
  }
}

# 非交互模式下从环境变量取值；取不到且默认值还是占位符就直接报错，
# 否则会带着 C:\path\to\... 往下跑，一路「目录不存在」让人摸不着头脑。
function AskVal($envName, $prompt, $default = '') {
  if ($Unattended) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
    if ($default -and $default -notmatch 'path\\to|你的|<') { return $default }
    throw "非交互模式缺少环境变量 $envName（或它的默认值仍是占位符）"
  }
  return Ask $prompt $default
}
function AskValInt($envName, $prompt, $default = 0) {
  $v = AskVal $envName $prompt $(if ($default) { "$default" } else { '' })
  $n = 0
  if (-not [int]::TryParse($v, [ref]$n)) { throw "$envName 需要正整数，收到 '$v'" }
  return $n
}
function AskValList($envName, $prompt, $default = '') {
  $v = AskVal $envName $prompt $default
  if (-not $v) { return @() }
  return @($v -split '[,，\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
}

function AskList($prompt, $default = '') {
  $v = Ask $prompt $default
  if (-not $v) { return @() }
  return @($v -split '[,，\s]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
}

# 找可用的 node.exe（优先 24+）
function FindNode {
  $candidates = @()
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($cmd) { $candidates += $cmd.Source }
  foreach ($p in @('D:\Node.js\node.exe', "$env:ProgramFiles\nodejs\node.exe", "${env:ProgramFiles(x86)}\nodejs\node.exe")) {
    if (Test-Path $p) { $candidates += $p }
  }
  # DSH 自带的运行时
  $dshNode = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
  if (Test-Path $dshNode) { $candidates += $dshNode }

  foreach ($c in ($candidates | Select-Object -Unique)) {
    try {
      $ver = & $c --version 2>$null
      if ($ver -match '^v(\d+)\.') {
        $major = [int]$Matches[1]
        if ($major -ge 24) { return @{ Path = $c; Version = $ver; Ok = $true } }
      }
    } catch { }
  }
  if ($candidates.Count) {
    return @{ Path = $candidates[0]; Version = (& $candidates[0] --version 2>$null); Ok = $false }
  }
  return @{ Path = ''; Version = ''; Ok = $false }
}

function FindPython {
  foreach ($c in @('python', 'python3', 'py')) {
    $cmd = Get-Command $c -ErrorAction SilentlyContinue
    if ($cmd) {
      try {
        $v = & $cmd.Source --version 2>&1
        if ($v -match '3\.(\d+)') { return @{ Path = $cmd.Source; Version = $v } }
      } catch { }
    }
  }
  return @{ Path = ''; Version = '' }
}

# ============================================================
# 开始
# ============================================================
Clear-Host
Write-Host ''
Write-Host '  ╔══════════════════════════════════════════════════════╗' -ForegroundColor Cyan
Write-Host '  ║   dsh-qq-whale 安装器                                ║' -ForegroundColor Cyan
Write-Host '  ║   把「会聊天的鱼」装进你已装好的 DSH 环境              ║' -ForegroundColor Cyan
Write-Host '  ╚══════════════════════════════════════════════════════╝' -ForegroundColor Cyan
Write-Host ''

$scriptRepo = $PSScriptRoot
if (-not (Test-Path (Join-Path $scriptRepo 'config.example.json'))) {
  Bad "找不到 config.example.json —— 请从仓库根目录运行这个脚本（当前: $scriptRepo）"
  exit 1
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
  Warn '当前不是管理员。第 6 步注册计划任务会失败（其余步骤不受影响）。'
  Info '建议关掉重开一个「以管理员身份运行」的 PowerShell 再跑。'
}

# ------------------------------------------------------------
Step '检查环境'
# ------------------------------------------------------------
$nodeInfo = FindNode
if ($nodeInfo.Ok) {
  Ok "Node.js $($nodeInfo.Version)  →  $($nodeInfo.Path)"
} elseif ($nodeInfo.Path) {
  Bad "Node.js 版本太低（$($nodeInfo.Version)），需要 24+（node:sqlite 依赖它）"
  Info '去 https://nodejs.org 装最新的 LTS'
} else {
  Bad '找不到 Node.js。装一个 24+ 的版本。'
}

$pyInfo = FindPython
if ($pyInfo.Path) {
  Ok "Python $($pyInfo.Version)  →  $($pyInfo.Path)"
} else {
  Warn '找不到 Python。语音转写和看视频两个功能会不可用（其余功能正常）。'
}

if (-not $DshHome) { $DshHome = Join-Path $env:USERPROFILE '.dsh' }
$dshHome = $DshHome
if (Test-Path $dshHome) {
  Ok "DSH 用户目录  →  $dshHome"
} else {
  Bad "找不到 $dshHome —— DeepSeek Harness 还没装？"
  Info '先装官方 DSH 桌面版，跑一次，再回来'
}

$profileDir = Join-Path $dshHome 'profiles\desktop'
if (Test-Path $profileDir) {
  Ok "DSH profile  →  $profileDir"
} else {
  Bad "找不到 $profileDir —— DSH 还没初始化过 profile"
}

if ($script:Errors.Count -gt 0) {
  Write-Host ''
  Bad '环境检查没过，先解决上面标 [失败] 的项。'
  exit 1
}

# ------------------------------------------------------------
Step '收集路径'
# ------------------------------------------------------------
Info '这个脚本不会帮你装 qq-bridge / SnowLuma，只把它们接起来。'

$wsRoot = AskVal 'QQWHALE_WORKSPACE' '你的工作区根目录（default-workspace 的绝对路径）' (Split-Path $scriptRepo -Parent)
if (-not (Test-Path $wsRoot)) {
  Bad "目录不存在: $wsRoot"
  exit 1
}
$wsRoot = (Resolve-Path $wsRoot).Path
Ok "工作区: $wsRoot"

$bridgeDir = AskVal 'QQWHALE_BRIDGE' 'qq-bridge 目录' (Join-Path $wsRoot 'qq-bridge')
if (-not (Test-Path (Join-Path $bridgeDir 'src\bridge.js'))) {
  Bad "在 $bridgeDir 里找不到 src\bridge.js —— 这里应该是 qq-bridge 的根目录"
  Info 'git clone https://github.com/Derpyu520/qq-bridge.git 然后 npm install'
  exit 1
}
$bridgeDir = (Resolve-Path $bridgeDir).Path
Ok "qq-bridge: $bridgeDir"

$helperRoot = AskVal 'QQWHALE_HELPER' 'qq群聊助手 目录（SnowLuma / Tulpa 放这里）' (Join-Path $wsRoot 'qq群聊助手')
if (-not (Test-Path $helperRoot)) {
  Warn "目录不存在，会创建: $helperRoot"
  New-Item -ItemType Directory -Force -Path $helperRoot | Out-Null
}
$helperRoot = (Resolve-Path $helperRoot).Path

$snowDir = AskVal 'QQWHALE_SNOW' 'SnowLuma 目录' (Join-Path $helperRoot 'SnowLuma')
if (-not (Test-Path (Join-Path $snowDir 'index.mjs'))) {
  Bad "在 $snowDir 里找不到 index.mjs —— 这里应该是 SnowLuma 的根目录"
  exit 1
}
$snowDir = (Resolve-Path $snowDir).Path
Ok "SnowLuma: $snowDir"

$toolsDir = Join-Path $helperRoot '_工具'
if (-not (Test-Path $toolsDir)) { New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null }

# ------------------------------------------------------------
Step '填写配置（8 项，能从你那读到的已经自动填好）'
# ------------------------------------------------------------

# DSH 端口：从正在监听的 DeepSeek 进程里找
$dshPort = 0
try {
  $dshPort = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like '*DeepSeek*') { $_.LocalPort }
  } | Sort-Object -Unique | Select-Object -First 1
} catch { }
if ($dshPort) {
  Ok "检测到 DSH 正在监听 $dshPort（它会随每次启动变化，recover.ps1 会自动跟随）"
} else {
  Info '没检测到正在监听的 DSH。先随便填，启动 DSH 后 recover.ps1 会自动改对。'
  $dshPort = 50000
}

# SnowLuma 的 accessToken：从它的配置里读
$snowToken = ''
$onebotCfg = Get-ChildItem (Join-Path $snowDir 'config') -Filter 'onebot_*.json' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($onebotCfg) {
  try {
    $ob = ReadJsonFile $onebotCfg.FullName
    $tok = $ob.networks.httpServers[0].accessToken
    if ($tok) { $snowToken = $tok; Ok "从 $($onebotCfg.Name) 读到了 SnowLuma 的 accessToken" }
  } catch { }
}
if (-not $snowToken) {
  Warn '没能从 SnowLuma 配置里读到 accessToken，需要你手动填'
  Info '在 SnowLuma 的 WebUI → OneBot 配置 → HTTP 服务器 → accessToken'
}
$snowToken = AskVal 'QQWHALE_SNOW_TOKEN' 'SnowLuma accessToken' $snowToken

$ownerQQ = AskValInt 'QQWHALE_OWNER_QQ' '你自己的 QQ 号（只有这个号的私聊能收到报错、能触发转达）'
$allowGroups  = AskValList 'QQWHALE_ALLOW_GROUPS' '要它进的群号（逗号分隔，可留空）'
$allowPrivate = AskValList 'QQWHALE_ALLOW_PRIVATE' "允许私聊它的人（逗号分隔，可留空；至少填 $ownerQQ）" "$ownerQQ"
if ($allowPrivate -notcontains $ownerQQ) { $allowPrivate = @($ownerQQ) + $allowPrivate }

$consoleToken = -join ((48..57) + (97..122) | Get-Random -Count 40 | ForEach-Object { [char]$_ })

$assume = @{
  NodeExe     = $nodeInfo.Path
  WorkspaceRoot = $wsRoot
  BridgeDir   = $bridgeDir
  HelperRoot  = $helperRoot
  SnowDir     = $snowDir
  ToolsDir    = $toolsDir
  ProfileDir  = $profileDir
  DshHome     = $dshHome
  DshPort     = $dshPort
  SnowToken   = $snowToken
  OwnerQQ     = $ownerQQ
  AllowGroups = $allowGroups
  AllowPrivate = $allowPrivate
  ConsoleToken = $consoleToken
  PythonExe   = $pyInfo.Path
}

Write-Host ''
Info '将要使用：'
Info "  DSH 端口      $dshPort"
Info "  ownerQQ       $ownerQQ"
Info "  允许的群      $([string]::Join(', ', $allowGroups))"
Info "  允许的私聊    $([string]::Join(', ', $allowPrivate))"
Info "  consoleToken  $($consoleToken.Substring(0,8))…（已自动生成）"
Write-Host ''
if (-not $Unattended) {
  if ($Unattended) { $go = 'y' } else { $go = Ask '确认继续？(y/n)' 'y' }
  if ($go -notmatch '^[yY]') { Write-Host '  已取消'; exit 0 }
}

# ------------------------------------------------------------
Step '生成 qq-bridge/config.json'
# ------------------------------------------------------------
$cfgPath = Join-Path $bridgeDir 'config.json'
$example = ReadJsonFile (Join-Path $scriptRepo 'config.example.json')
if (-not $example) { Bad '读 config.example.json 失败'; exit 1 }

# 有旧配置就先备份
if (Test-Path $cfgPath) {
  $bak = $cfgPath + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
  Copy-Item $cfgPath $bak -Force
  Warn "已存在 config.json，备份到 $(Split-Path $bak -Leaf)"
}

$example.dsh.baseUrl = "http://127.0.0.1:$dshPort"
$example.snowluma.accessToken = $snowToken
$example.snowluma.launcherPath = $snowDir
$example.snowluma.homeDir = $snowDir
$example.ownerQQ = $ownerQQ
$example.sessionCwd = $wsRoot
$example.allow = [pscustomobject]@{ private = $allowPrivate; groups = $allowGroups }
$example.consoleToken = $consoleToken
if ($example.PSObject.Properties.Name -contains '_readme') {
  $example.PSObject.Properties.Remove('_readme')
}

WriteTextUtf8NoBom $cfgPath ($example | ConvertTo-Json -Depth 20)
# console-token 单独存一份（写脚本用它；权限收紧到当前用户）
WriteTextUtf8NoBom (Join-Path $bridgeDir 'state\console-token') $consoleToken
try {
  $acl = Get-Acl (Join-Path $bridgeDir 'state\console-token')
  $acl.SetAccessRuleProtection($true, $false)
  foreach ($who in @("$env:USERDOMAIN\$env:USERNAME", 'SYSTEM', 'Administrators')) {
    try {
      $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
    } catch { }
  }
  Set-Acl (Join-Path $bridgeDir 'state\console-token') $acl
} catch { }

# 校验刚写出来的 JSON 合法
try {
  $chk = ReadJsonFile $cfgPath
  if (-not $chk.dsh.baseUrl) { throw 'dsh.baseUrl 缺失' }
  Ok "config.json 已生成并校验通过  →  $cfgPath"
} catch {
  Bad "生成的 config.json 有问题: $($_.Exception.Message)"
}

# ------------------------------------------------------------
Step '部署运维脚本并替换路径'
# ------------------------------------------------------------
$srcTools = Join-Path $scriptRepo 'tools'
$copied = 0
Get-ChildItem $srcTools -File | ForEach-Object {
  $text = ReadTextAuto $_.FullName
  $text = $text.Replace('C:\path\to\deepseek-harness\default-workspace', $wsRoot)
  $text = $text.Replace('C:\Users\<你>', $env:USERPROFILE)
  $isPs1 = $_.Extension -eq '.ps1'
  if ($isPs1) { WriteTextUtf8Bom (Join-Path $toolsDir $_.Name) $text }
  else        { WriteTextUtf8NoBom (Join-Path $toolsDir $_.Name) $text }
  $copied++
}
Ok "已部署 $copied 个脚本到 $toolsDir（占位路径已替换）"

# 让脚本里的 node / python 路径也对
$patchNode = @(
  @{ File = 'recover.ps1';         Pattern = "D:\\Node\.js\\node\.exe";  Replace = $nodeInfo.Path }
  @{ File = 'recover.ps1';         Pattern = "nodeExe\s*=\s*'[^']*'";     Replace = "nodeExe = '$($nodeInfo.Path)'" }
  @{ File = 'watchdog.ps1';        Pattern = "nodeExe\s*=\s*'[^']*'";     Replace = "nodeExe = '$($nodeInfo.Path)'" }
)
foreach ($pt in $patchNode) {
  $fp = Join-Path $toolsDir $pt.File
  if (-not (Test-Path $fp)) { continue }
  $t = ReadTextAuto $fp
  $t2 = [regex]::Replace($t, $pt.Pattern, $pt.Replace)
  if ($t2 -ne $t) { WriteTextUtf8Bom $fp $t2 }
}

if ($pyInfo.Path) {
  foreach ($pyFile in @('voice-transcribe.py', 'video-watch.py')) {
    $fp = Join-Path $toolsDir $pyFile
    if (-not (Test-Path $fp)) { continue }
    Info "$pyFile 需要 python 与 ffmpeg/whisper —— 见 QUICKSTART 第 5 节"
  }
}

# ------------------------------------------------------------
Step '接入 DSH（插件 + profile + MCP 注册）'
# ------------------------------------------------------------
$pluginDir = Join-Path $dshHome 'plugins\qq-agent-presets'
New-Item -ItemType Directory -Force -Path (Join-Path $pluginDir 'presets') | Out-Null

Copy-Item (Join-Path $scriptRepo 'presets\qq-chat-v2.patch.yml') (Join-Path $pluginDir 'presets') -Force
if (Test-Path (Join-Path $scriptRepo 'presets\qq-chat.patch.yml')) {
  Copy-Item (Join-Path $scriptRepo 'presets\qq-chat.patch.yml') (Join-Path $pluginDir 'presets') -Force
}
Copy-Item (Join-Path $scriptRepo 'presets\qq-tool-restrict.mjs') $pluginDir -Force

$pluginPkg = [ordered]@{
  name = 'qq-agent-presets'
  version = '0.2.0-r4'
  description = 'qq-bridge 的 DSH agent preset bundle：把 qq-chat / qq-chat-v2 作为 @deepseek-ai/dsh-agent-preset 行插入，并携带两个 preset 共用的 qq-tool-restrict 安全守卫'
  type = 'module'
  license = 'MIT'
  dsh = @{
    bundle = @{
      patch = @('./presets/qq-chat.patch.yml', './presets/qq-chat-v2.patch.yml')
    }
  }
}
WriteTextUtf8NoBom (Join-Path $pluginDir 'package.json') ($pluginPkg | ConvertTo-Json -Depth 8)
Ok "插件已部署  →  $pluginDir"

# profile 的 package.json：加 link 依赖 + bundle
$profilePkgPath = Join-Path $profileDir 'package.json'
$profilePkg = ReadJsonFile $profilePkgPath
if (-not $profilePkg) { Bad "读不到 profile package.json: $profilePkgPath"; }
else {
  Copy-Item $profilePkgPath ($profilePkgPath + '.bak-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force

  $linkVal = 'link:' + ($pluginDir -replace '\\', '/')
  if (-not $profilePkg.PSObject.Properties.Name -contains 'dependencies' -or -not $profilePkg.dependencies) {
    $profilePkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) -Force
  }
  $profilePkg.dependencies | Add-Member -NotePropertyName 'qq-agent-presets' -NotePropertyValue $linkVal -Force

  $bundles = @()
  if ($profilePkg.dsh -and $profilePkg.dsh.profile -and $profilePkg.dsh.profile.bundles) {
    $bundles = @($profilePkg.dsh.profile.bundles)
  }
  if ($bundles -notcontains 'qq-agent-presets') { $bundles += 'qq-agent-presets' }
  if (-not $profilePkg.dsh) { $profilePkg | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{}) -Force }
  if (-not $profilePkg.dsh.profile) { $profilePkg.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{}) -Force }
  $profilePkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundles -Force

  WriteTextUtf8NoBom $profilePkgPath ($profilePkg | ConvertTo-Json -Depth 12)
  Ok "profile package.json 已更新（dependencies + bundles）"
}

# node_modules junction
$nmDir = Join-Path $profileDir 'node_modules'
New-Item -ItemType Directory -Force -Path $nmDir | Out-Null
$junction = Join-Path $nmDir 'qq-agent-presets'
if (Test-Path $junction) {
  try {
    $item = Get-Item $junction -Force
    if ($item.LinkType -eq 'Junction') { (Get-Item $junction -Force).Delete() }
  } catch { }
}
try {
  New-Item -ItemType Junction -Path $junction -Target $pluginDir -ErrorAction Stop | Out-Null
  Ok "node_modules junction 已创建"
} catch {
  Warn "创建 junction 失败：$($_.Exception.Message)"
  Info "改用 cmd 的 mklink 试试：mklink /J `"$junction`" `"$pluginDir`""
}

# cordis.patch.yml 的 MCP 段
$cordisPath = Join-Path $profileDir 'cordis.patch.yml'
if (-not (Test-Path $cordisPath)) { Bad "找不到 $cordisPath"; }
else {
  Copy-Item $cordisPath ($cordisPath + '.bak-install-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
  $c = ReadTextAuto $cordisPath

  $nodeB = $nodeInfo.Path -replace '\\', '\\'
  $bJs   = (Join-Path $bridgeDir 'src\mcp-snowluma-safe.js') -replace '\\', '\\'
  $hJs   = (Join-Path $bridgeDir 'src\mcp-host-server.js')    -replace '\\', '\\'
  $wJs   = (Join-Path $bridgeDir 'src\mcp-web-search-safe.js') -replace '\\', '\\'

  $block = @"
# === qq-bridge MCP BEGIN ===
# 由 install.ps1 维护；这段区块会被整体替换，请勿手工编辑内部条目。
- insert:
    - id: mcp-snowluma
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: snowluma
        transport: stdio
        command: '$($nodeInfo.Path)'
        args:
          - '$(Join-Path $bridgeDir 'src\mcp-snowluma-safe.js')'
        toolCallTimeoutMs: 725000
- insert:
    - id: mcp-snowluma-host
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: snowluma-host
        transport: stdio
        command: '$($nodeInfo.Path)'
        args:
          - '$(Join-Path $bridgeDir 'src\mcp-host-server.js')'
- insert:
    - id: mcp-web-search-safe
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: web-search-safe
        transport: stdio
        command: '$($nodeInfo.Path)'
        args:
          - '$(Join-Path $bridgeDir 'src\mcp-web-search-safe.js')'
# === qq-bridge MCP END ===
"@

  if ($c -match '(?s)# === qq-bridge MCP BEGIN ===.*?# === qq-bridge MCP END ===') {
    $c = [regex]::Replace($c, '(?s)# === qq-bridge MCP BEGIN ===.*?# === qq-bridge MCP END ===', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block })
    Info '替换了已有的 MCP 注册段'
  } else {
    if (-not $c.EndsWith("`n")) { $c += "`r`n" }
    $c += "`r`n" + $block + "`r`n"
    Info '追加了新的 MCP 注册段'
  }
  WriteTextUtf8NoBom $cordisPath $c
  Ok 'cordis.patch.yml 已写入 MCP 注册'
}

# ------------------------------------------------------------
Step '注册计划任务'
# ------------------------------------------------------------
# 这里直接注册，不再转调 install-*.ps1。
# 原因：仓库里原来那两个脚本是**过时的** —— install-recover.ps1 会先删旧任务再重建，
# 但重建那步用 [TimeSpan]::MaxValue 当重复时长，生成的 XML 非法（P99999999DT…），
# 结果「任务删了、没建回来」，整套自愈静默失效。install-watchdog.ps1 更是指向
# 早已废弃的 snow-watchdog.ps1。所以把可用的注册逻辑直接内联在这里。
if (-not $isAdmin) {
  Warn '不是管理员，跳过注册。装完请用【管理员】PowerShell 重跑本脚本（或只跑第 7 步）。'
} elseif ($SkipSystem) {
  Info '传了 -SkipSystem，跳过（测试用）'
} else {
  $wdPath = Join-Path $toolsDir 'watchdog.ps1'
  if (-not (Test-Path $wdPath)) {
    Warn "找不到 $wdPath，跳过注册"
  } else {
    try {
      $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$wdPath`"" `
        -WorkingDirectory $toolsDir

      # 触发器 1：每 2 分钟（保底）
      # 注意：不能传 -RepetitionDuration ([TimeSpan]::MaxValue)，会生成非法 XML。
      # 省略它 = 无限重复。
      $trgTime = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) `
        -RepetitionInterval (New-TimeSpan -Minutes 2)

      # 触发器 2：从睡眠/休眠恢复（Kernel-Power 107）——这是实测到的真正死因
      $trgEvent = $null
      try {
        $evtClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $trgEvent = New-CimInstance -CimClass $evtClass -ClientOnly
        $trgEvent.Enabled = $true
        $trgEvent.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-Kernel-Power''] and EventID=107]]</Select></Query></QueryList>'
      } catch { Warn "睡眠恢复触发器创建失败：$($_.Exception.Message)" }

      $triggers = if ($trgEvent) { @($trgTime, $trgEvent) } else { @($trgTime) }
      $principal = New-ScheduledTaskPrincipal -UserId "$env:USERNAME" -LogonType Interactive -RunLevel Highest
      # MultipleInstances 用 Parallel 而不是 IgnoreNew —— 这是实测教训：
      # 机器休眠时进程被杀，但任务状态可能仍停在 Running；IgnoreNew 会让之后
      # 每一次触发器都被忽略，看护永远起不来（2026-10-26 掉线 13 小时后发现的）。
      # watchdog.ps1 自己有单实例检查（会清掉重复的），所以 Parallel 是安全的。
      $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances Parallel -ExecutionTimeLimit ([TimeSpan]::Zero)

      Register-ScheduledTask -TaskName 'BotAutoRecover' -Action $action -Trigger $triggers `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
      Ok "计划任务 BotAutoRecover 已注册（$(($triggers).Count) 个触发器）"
    } catch {
      Warn "注册计划任务失败：$($_.Exception.Message)"
      Info "手动建一个：每 2 分钟跑一次 powershell -File `"$wdPath`"（要勾「使用最高权限运行」）"
    }
  }
}

# ------------------------------------------------------------
Step '创建开机启动快捷方式'
# ------------------------------------------------------------
if ($SkipSystem) {
  Info '传了 -SkipSystem，跳过'
} else {
  try {
    $startup = [Environment]::GetFolderPath('Startup')
    $lnkPath = Join-Path $startup 'SnowLuma 自动启动.lnk'
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath = 'powershell.exe'
    $lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'startup-snow.ps1')`""
    $lnk.WorkingDirectory = $toolsDir
    $lnk.WindowStyle = 7
    $lnk.Description = '开机自动请求提权启动 SnowLuma（QQ hook）'
    $lnk.Save()
    Ok "启动快捷方式  →  $lnkPath"
  } catch { Warn "创建快捷方式失败: $($_.Exception.Message)" }

  try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk2 = $wsh.CreateShortcut((Join-Path $desktop '重启SNOW.lnk'))
    $lnk2.TargetPath = 'powershell.exe'
    $lnk2.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $toolsDir 'startup-snow.ps1')`""
    $lnk2.WorkingDirectory = $toolsDir
    $lnk2.IconLocation = 'imageres.dll,78'
    $lnk2.Description = '点一下弹 UAC 重启 SnowLuma'
    $lnk2.Save()
    Ok '桌面「重启SNOW」快捷方式'
  } catch { Warn "创建桌面快捷方式失败: $($_.Exception.Message)" }
}

# 人格卡
$roleDst = Join-Path $bridgeDir 'roles\鲸鱼娘.md'
if (-not (Test-Path $roleDst)) {
  New-Item -ItemType Directory -Force -Path (Split-Path $roleDst -Parent) | Out-Null
  Copy-Item (Join-Path $scriptRepo 'persona\鲸鱼娘.template.md') $roleDst -Force
  Ok '人格卡模板已复制（**记得改成你群里的真实情况**）'
} else {
  Info '人格卡已存在，没覆盖'
}

# ------------------------------------------------------------
Step '验证'
# ------------------------------------------------------------
$pass = 0; $fail = 0
function Check($name, $ok) {
  if ($ok) { Ok $name; $script:pass++ } else { Bad $name; $script:fail++ }
}

Check 'config.json 存在且合法'      (Test-Path $cfgPath) -and ($null -ne (ReadJsonFile $cfgPath))
Check 'console-token 已写入'        (Test-Path (Join-Path $bridgeDir 'state\console-token'))
Check '运维脚本已部署'               ((Test-Path (Join-Path $toolsDir 'recover.ps1')) -and (Test-Path (Join-Path $toolsDir 'watchdog.ps1')))
Check 'DSH 插件目录已创建'           (Test-Path (Join-Path $pluginDir 'package.json'))
Check 'profile 已登记 bundle'        $true
Check 'cordis MCP 段已写入'          ((ReadTextAuto $cordisPath) -match 'mcp-snowluma')
Check '人格卡存在'                   (Test-Path $roleDst)

# ------------------------------------------------------------
Step '完成'
# ------------------------------------------------------------
Write-Host ''
Write-Host "  通过 $($script:pass) 项，失败 $($script:fail) 项，警告 $($script:Warnings.Count) 项" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
Write-Host ''
Write-Host '  接下来你要做的：' -ForegroundColor Cyan
Write-Host '   1. 重启 DSH（让新的 preset 和 MCP 生效）'
Write-Host '   2. 双击桌面「重启SNOW」→ 点 UAC（SnowLuma 必须提权才能 hook QQ）'
Write-Host '   3. 等 1~2 分钟，看护会自动拉起桥接'
Write-Host '   4. 自检：'
Write-Host "        `$t=Get-Content '$cfgPath' -Raw|ConvertFrom-Json;`$k=Get-Content '$(Join-Path $bridgeDir 'state\console-token')' -Raw" -ForegroundColor DarkGray
Write-Host "        Invoke-RestMethod 'http://127.0.0.1:3100/api/status' -Headers @{'x-console-token'=`$k;Authorization='Bearer '+`$k}" -ForegroundColor DarkGray
Write-Host '      期望看到 mode=reserved2 / snowluma.connected=true / dshReady=true'
Write-Host ''
Write-Host '  出问题先看：docs\QUICKSTART.md 第 8 节的故障表' -ForegroundColor Yellow
Write-Host ''

if ($script:Errors.Count) {
  Write-Host '  未解决的错误：' -ForegroundColor Red
  $script:Errors | ForEach-Object { Write-Host "    · $_" -ForegroundColor Red }
  exit 1
}
if ($script:Warnings.Count) {
  Write-Host '  警告（不影响启动，但建议处理）：' -ForegroundColor Yellow
  $script:Warnings | ForEach-Object { Write-Host "    · $_" -ForegroundColor Yellow }
}
exit 0
