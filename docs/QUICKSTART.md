# QUICKSTART · 从零到跑通

> **如果你已经装好了 DSH / qq-bridge / SnowLuma，直接跑仓库根目录的 .\install.ps1（管理员）——它会做完后面第 2~6 步。**
>`n> 这份文档假设你**什么都没装**。跟着做大概需要 2~3 小时，中间会卡两三次，卡住的地方在第 7 节。

---

## 0. 你需要准备什么

| 东西 | 说明 |
|---|---|
| **Windows 10/11** | 全程 Windows。脚本是 PowerShell 5.1 写的，别指望在 Linux 上直接跑 |
| **一个 QQ 小号** | 建议用新注册的号，别拿主号试——协议端有封号风险 |
| **DeepSeek Harness（DSH）** | 官方桌面版。本项目所有"性格"都跑在 DSH 会话里 |
| **Node.js 24** | `node:sqlite` 需要 24+。qq-bridge 和 SnowLuma 都用它 |
| **Python 3.12** | 只给 `voice-transcribe.py` / `video-watch.py` 用 |
| **ffmpeg** | 抽帧和转音频。本项目复用 Tulpa 里的那份，你也可以单独装 |
| **一个 DeepSeek 账号余额** | 每条消息都会真的调模型。欠费时它会往群里刷报错（本项目已修，但还是要钱） |

---

## 1. 装 SnowLuma（QQ 协议端）

SnowLuma 负责"让程序能收发 QQ 消息"。

1. 下载 SnowLuma，解压到 `你的工作区\qq群聊助手\SnowLuma\`
2. 直接起一次 `node.exe index.mjs`，用管理界面（默认 `http://127.0.0.1:5099`）扫码登录你的 QQ 小号
3. **关掉它**，后面要用提权方式启动

### ⚠️ 这一节是全程最大的坑，先读完

SnowLuma 的 hook（注入 QQ 进程）**必须有特定的权限令牌**。实测结论：

| 启动方式 | 能不能 hook 上 QQ |
|---|---|
| 双击启动（普通权限） | ❌ `/api/processes` 返回空列表 |
| 计划任务（`RunLevel: Highest`） | ❌ 同样是空列表 |
| **UAC 弹窗确认启动（consent.exe）** | ✅ 3 秒内 hook 成功 |

**而且失败时它不报错**——日志只有一行 `hook auto-load enabled: every discovered QQ process will be injected`，然后什么都不做。WebUI 起来了、5099 在听，只有 3000/3001 永远不通。

**诊断方法**（记住这个，能省你两小时）：

```powershell
# 登录 WebUI
$body = @{ password = '你的WebUI密码' } | ConvertTo-Json
$login = Invoke-RestMethod -Uri 'http://127.0.0.1:5099/api/login' -Method Post -ContentType 'application/json' -Body $body
# 查它扫到几个 QQ 进程
Invoke-RestMethod -Uri 'http://127.0.0.1:5099/api/processes' -Headers @{ Authorization = 'Bearer ' + $login.token }
```

- 返回 `{"list":[]}` → **没提权 / 没扫到 QQ**，别浪费时间查别的
- 返回带 `"injected":true,"loggedIn":true` → 正常

**另一个坑**：强杀 SnowLuma 之后 QQ 里会留着指向死进程的 hook，重启 SnowLuma 也 hook 不上。**必须连 QQ 一起重启**。

---

## 2. 装 qq-bridge

```powershell
cd 你的工作区
git clone https://github.com/Derpyu520/qq-bridge.git
cd qq-bridge
npm install
```

**然后用本仓库 `bridge/` 下的 7 个文件覆盖它的 `src/`：**

```powershell
Copy-Item 本仓库\bridge\*.js 你的工作区\qq-bridge\src\ -Force
```

**再装预设**（DSH 的 agent preset）：

```powershell
Copy-Item 本仓库\presets\qq-chat-v2.patch.yml $env:USERPROFILE\.dsh\plugins\qq-agent-presets\presets\ -Force
Copy-Item 本仓库\presets\qq-tool-restrict.mjs $env:USERPROFILE\.dsh\plugins\qq-agent-presets\ -Force
```

> 这个预设通过 `cordis.patch.yml` 挂进 DSH。如果你没用过 qq-bridge 的 DSH 集成，先看上游仓库的 `scripts/setup-dsh.mjs`——它会把 MCP 服务端注册进 DSH 的 profile。

---

## 3. 写 config.json

`qq-bridge/config.json` **不会被提交到仓库**（里面有密钥）。

**直接复制仓库根目录的 `config.example.json`** 改个名：

```powershell
Copy-Item config.example.json 你的工作区\qq-bridge\config.json
```

它是从一份**真实运行的配置**导出的，200+ 个字段齐全、自带我们调好的参数。你只需要改 **8 处**（`<>` 包着的那些）：

| # | 字段 | 填什么 |
|---|---|---|
| 1 | `dsh.baseUrl` | `http://127.0.0.1:<DSH 端口>`。**DSH 每次启动端口都变**，随便填一个，`recover.ps1` 会自动改对 |
| 2 | `snowluma.accessToken` | SnowLuma WebUI → OneBot 配置里的 accessToken |
| 3 | `snowluma.launcherPath` | SnowLuma 解压目录的绝对路径 |
| 4 | `snowluma.homeDir` | 同上 |
| 5 | `ownerQQ` | 你自己的 QQ 号（**只有这个号的私聊能收到报错、能触发转达**） |
| 6 | `sessionCwd` | 你的工作区绝对路径 |
| 7 | `allow` | `groups` 填要它进的群号，`private` 填允许私聊它的人 |
| 8 | `consoleToken` | 自己随便打一串长的（之后所有控制台请求都用它） |

**其余字段的含义：**

- `socialV2.wake` —— 唤醒策略。`minProbability: 0.2` 是**我们加的下限**（防止 AI 把自己调到 0.05 导致叫不醒）
- `socialV2.context` —— 缓冲区大小。`recentLimit: 300` / `unreadLimit: 120`，默认的 100/30 在活跃群会丢消息
- `socialV2.tools` —— 工具开关。`mood` / `relay` / `watchVideo` 是我们新增的
- `role.maxInjectChars` —— 人格卡注入上限。默认 1000 太小，建议 12000
- `slang` / `social` / `pricing` / `webSearch` —— 上游功能，保持默认即可

### 可调参数（记忆 / 心情 / 轮换）

这三段的参数**原来是写死在代码里的**，现在可以从配置改。

**记忆** `socialV2.memory`

| 参数 | 默认 | 作用 |
|---|---|---|
| `halfLifeDays` | `{1:2, 2:7, 3:14, 4:30, 5:90}` | 重要度 1~5 各自几天淡到一半。想让它记性更长就调大 |
| `pruneWeight` | `0.03` | 权重低于这个才真删。**调 0 = 永不删除**（只降权重不清理） |
| `maxEntries` | `40` | 话题上限，超了挤掉权重最低的 |
| `reviveMinGrams` | `2` | 被重新提起的判定阈值：几个 3 字片段同时命中才算 |
| `activeTopicMaxAgeHours` | `6` | **「进行中话题」的新鲜度上限**。超过就不当「正在聊」注入了 |
| `activeTopicMaxAgeHighHours` | `72` | 重要度 ≥4（约定、欠账）放宽到的上限 |
| `activeTopicInjectMax` | `10` | 每次最多注入几条进行中话题 |
| `embedEnabled` | `true` | **用本地 ollama 向量检索替代 3 字片段字面匹配** |
| `embedModel` | `bge-m3` | 需先 `ollama pull bge-m3`（1.2 GB）。没拉就自动退回字面匹配 |
| `embedUrl` | `http://127.0.0.1:11434` | ollama 地址 |
| `embedMinSim` | `0.60` | 相似度门槛。实测：该想起的 0.63~0.66，无关话题 ≤0.53 |

> **为什么加 `embed*` 这几项：** 原来「被重新提起」是 3 字片段**字面**匹配。
> 实测「碗我洗好了，你那份也别搁着」对「白饭票梗：我发的票盖碗印」是 **0 命中** ——
> 语义完全相关，但一个字都对不上，它想不起来。改成向量检索后同一句命中 0.637。
> ollama 不在/超时一律自动退回字面匹配，**不会报错**。


> **为什么需要 `activeTopicMaxAgeHours`：** 只按权重排序时，权重半衰期是 14 天 ——
> 20 小时前的话题权重还有 0.96，等于永远「正在进行」。实测群里 12 条进行中话题
> 有 11 条是同一个人的旧账、最久的 20 小时前，它每次接话都从老账里捞素材，
> 群友看到的就是「前言不搭后语」。这道闸只影响**注入**，不删状态。

**心情** `socialV2.mood`

| 参数 | 默认 | 作用 |
|---|---|---|
| `overallHalfLifeHours` | `12` | 总心情回落一半要几小时（隔一夜还有余温） |
| `valueHalfLifeMinutes` | `90` | 单根情绪消散一半要几分钟 |
| `stepScale` | `0.3333333` | **步长削到多少**。调 1 = 不削，但情绪判定天然偏正，不削会永远满格 = 没有心情 |
| `maxStep` | `20` | 单次单根上限 |
| `biasOverallHalfLifeMinutes` | `45` | 会话偏移的总心情半衰期 |
| `biasValueHalfLifeMinutes` | `30` | 会话偏移的单根情绪半衰期 |

**QQ 空间** `socialV2.qzone`

| 参数 | 默认 | 作用 |
|---|---|---|
| `enabled` | `true` | 是否注册空间工具 |
| `maxPerDay` | `1` | 每天最多发几条说说 |
| `ugcRight` | `1` | 默认可见性：1=所有人 4=好友 16=部分好友 64=仅自己 128=部分不可见 |
| `maxChars` | `300` | 单条字数上限 |

> 说说一旦发出去就长期可见，所以默认每天只给 1 条。想更活跃再调大。

**好友申请** `socialV2.friend`

| 参数 | 默认 | 作用 |
|---|---|---|
| `autoWhitelistMax` | `10` | 自动加入私聊白名单的名额上限（操作者手动加的不算） |

> 名额满了之后仍可同意好友，但不再自动加白名单。

**上下文轮换** `socialV2.rotate`

| 参数 | 默认 | 作用 |
|---|---|---|
| `turns` | `25` | 跑多少轮换新会话。**实测 38 轮开始卡死**（37 万 token 后只输出 step1） |
| `handoffRecentMessages` | `30` | 交接摘要带多少条最近消息 |
| `handoffMaxChars` | `2200` | 摘要上限。别调太大，否则新会话立刻又撑爆 |

**改法**（走接口，不是改文件）：

```powershell
$h = @{ 'x-console-token' = $tok; Authorization = 'Bearer ' + $tok }
$cur = (Invoke-RestMethod 'http://127.0.0.1:3100/api/socialV2/config' -Headers $h).config
$mood = $cur.mood
$mood.stepScale = 0.5          # 想让情绪变化更明显一点
Invoke-RestMethod 'http://127.0.0.1:3100/api/socialV2/config' -Method Post `
  -Headers $h -ContentType 'application/json' -Body (@{ mood = $mood } | ConvertTo-Json -Depth 8)
```

改完立刻生效，**不用重启桥接**。注意 `/api/socialV2/config` 只接受控制台令牌，不能带 agent token。

### ⚠️ 改配置的铁律

**不要直接改 `config.json` 然后重启。**

桥接把配置读进内存，它自愈时会把**内存里的旧副本**写回文件——你改的会被覆盖。
**必须走运行时接口**：

```powershell
$tok = Get-Content 你的工作区\qq-bridge\state\console-token -Raw
$h = @{ 'x-console-token' = $tok; Authorization = 'Bearer ' + $tok }
# 先把当前配置读出来
$cur = Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/socialV2/config' -Headers $h
# 只改 wake 段，其余原样带回去（服务端是浅合并，漏传的段会保留，但别赌）
$wake = $cur.config.wake
$wake.preSleepWaitMs = 120000
$wake.minProbability  = 0.2
Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/socialV2/config' -Method Post `
  -Headers $h -ContentType 'application/json' `
  -Body (@{ wake = $wake } | ConvertTo-Json -Depth 8)
```

**验证确实生效**（内存和文件都要看）：

```powershell
(Invoke-RestMethod -Uri 'http://127.0.0.1:3100/api/socialV2/config' -Headers $h).config.wake.preSleepWaitMs
(Get-Content 你的工作区\qq-bridge\config.json -Raw | ConvertFrom-Json).socialV2.wake.preSleepWaitMs
```

---

## 4. 装人格卡

```powershell
mkdir 你的工作区\qq-bridge\roles
Copy-Item 本仓库\persona\鲸鱼娘.template.md 你的工作区\qq-bridge\roles\鲸鱼娘.md
```

**然后必须改**——模板里的 `<你的角色名>` 之类占位、以及所有描述群友的部分，都要换成你群里真实的人和事。

**人格卡的写法有一条最重要的原则**（这是调了两天才明白的）：

> **写「她是谁」，不要写「她该怎么说」。**

写了「一条消息最多 15 字」，她就会数着字说话；写了「热闹的时候要挤进去」，她会先判断一下再挤。
前者是人，后者是执行指令的机器。

---

## 5. 装运维脚本

```powershell
Copy-Item 本仓库\tools\* 你的工作区\qq群聊助手\_工具\ -Force
```

**然后必须改路径**——所有脚本里写的 `C:\path\to\deepseek-harness\default-workspace` 都要换成你的实际路径：

```powershell
$dir = "你的工作区\qq群聊助手\_工具"
Get-ChildItem $dir -Include *.ps1,*.py -Recurse | ForEach-Object {
  (Get-Content $_.FullName -Raw -Encoding UTF8).Replace('C:\path\to\deepseek-harness\default-workspace','你的实际工作区路径') |
    Set-Content $_.FullName -Encoding UTF8
}
```

**PowerShell 5.1 的两个坑：**

1. 脚本必须存成 **UTF-8 with BOM**，否则中文全乱码
2. `Test-Path $a -and (Test-Path $b)` 会报「找不到与参数名称"and"匹配的参数」——**每个括号都要包起来**

---

## 6. 注册计划任务

```powershell
# 用管理员 PowerShell 跑
.\_工具\install-recover.ps1
.\_工具\install-watchdog.ps1
```

**会注册的：**

- `BotAutoRecover`：每 2 分钟跑 `watchdog.ps1`
- `watchdog.ps1` 单实例、持有电源请求（防止系统睡眠）、每轮调 `recover.ps1`

**`recover.ps1` 干什么**（按顺序）：

1. 找 DSH 实际监听端口（**每次启动都变**），改 `config.json` 的 `baseUrl`
2. 桥接不在 → 拉起
3. Tulpa 不在 → 重启
4. SnowLuma 不在 → **只诊断不重启**（因为计划任务启动不了它，见第 1 节）

**开机自动启动 SnowLuma**：把 `startup-snow.ps1` 的快捷方式放进启动文件夹：

```powershell
$startup = [Environment]::GetFolderPath('Startup')
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path $startup 'SnowLuma 自动启动.lnk'))
$lnk.TargetPath = 'powershell.exe'
$lnk.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"你的工作区\qq群聊助手\_工具\startup-snow.ps1`""
$lnk.Save()
```

它会先检查 3000 端口：已经通了就静默退出，不通才弹 UAC。

---

## 7. 验证清单

按顺序跑，每一步都要过：

```powershell
# ① SnowLuma hook 上了吗
Invoke-RestMethod 'http://127.0.0.1:5099/api/processes' -Headers $h | ConvertTo-Json -Depth 4
#   期望：list 里有 injected:true, loggedIn:true

# ② 桥接连上 SnowLuma 和 DSH 了吗
$tok = Get-Content 你的工作区\qq-bridge\state\console-token -Raw
Invoke-RestMethod 'http://127.0.0.1:3100/api/status' -Headers @{ 'x-console-token'=$tok; Authorization='Bearer '+$tok }
#   期望：mode=reserved2, role="鲸鱼娘", snowluma.connected=true, dshReady=true

# ③ 心情能用吗
Invoke-RestMethod 'http://127.0.0.1:3100/api/socialV2/mood?key=group:你的群号' -Headers @{...}
#   期望：ok=true, overall=50

# ④ 看视频能用吗（随便找个短 B 站视频）
python 你的工作区\qq群聊助手\_工具\video-watch.py "https://www.bilibili.com/video/BVxxxx" --frames 4
#   期望：{"ok":true, "frameCount":4, ...}
```

**全过之后，在小号所在群里发一句话，看它回不回。**

---

## 8. 常见故障

| 症状 | 先查什么 |
|---|---|
| 群里完全没反应 | `/api/processes` 是不是空列表 → 提权问题 |
| 它收到消息但不回 | 桥接日志有没有 `唤醒`；`probability` 是否被写成 0.05 |
| 回复越来越慢、最后不动 | 会话轮数是否超 25（上下文膨胀）。看 `auto-rotate.cjs --dry` |
| 改了配置重启就回退 | 你改了文件而不是走 API |
| 开机后要手动点 UAC | 正常现象。只有 consent.exe 的令牌能 hook |
| 桥接连不上 DSH | `config.json` 的 `baseUrl` 端口过期了。`recover.ps1` 每 2 分钟会修 |
| whisper 报 0xC0000409 | 非 ASCII 绝对路径。exe 用绝对、`-m`/`-f` 用相对、cwd 设到 Release 目录 |

---

## 9. 成本与风险

**成本**：每条群消息都会真的调一次模型（如果被唤醒）。一个活跃群一天可能几块钱。**欠费时它会刷报错**——本项目已修成只通知操作者，但你得保证余额。

**风险**：

- 协议端有封号风险，**用小号**
- 群友可能看出它是 AI（人格卡写得再好也只是降低概率）
- 它会自己维护"关注名单"，偶尔会把你不想理的人也加进去

---

## 10. 下一步

- 想改性格 → 看 `persona/鲸鱼娘.template.md`
- 想懂为什么这么设计 → 看 `DESIGN.md`
- 想知道踩过哪些坑 → 看 `README.md` 的「踩过的坑」表
