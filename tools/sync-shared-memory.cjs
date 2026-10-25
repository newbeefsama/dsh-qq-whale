// sync-shared-memory.cjs —— 把「跟每个人聊过什么」写成一段共享记忆，插进人格卡。
//
// 背景（2026-10-22）：
//   qq-bridge 的架构是「一个 QQ 会话 = 一个独立 DSH 会话」，
//   所以跟栩私聊时的上下文，罗辑那边看不到 —— 记忆天然隔离。
//   桥接的 qq_memory_* 也是按会话 key 存的，没有跨会话共享的开关。
//
// 解法：
//   人格卡（roles/鲸鱼娘.md）是**每条消息、每个会话都会注入**的。
//   所以在这里自动生成一段【最近跟谁聊了什么】，嵌进人格卡。
//   这样无论在跟谁说话，都能看到其他人的近况。
//
// 用法：
//   node sync-shared-memory.cjs          生成并写入人格卡
//   node sync-shared-memory.cjs --dry    只打印不写入
//
// 建议：由看护进程每小时跑一次（watchdog.ps1 里已经加了调用）。

const fs = require('node:fs');
const path = require('node:path');
const { DatabaseSync } = require('node:sqlite');

const BRIDGE_DIR = path.join(__dirname, '..', '..', 'qq-bridge');
const ROLE = path.join(BRIDGE_DIR, 'roles', '鲸鱼娘.md');
const DB = path.join(__dirname, '..', 'SnowLuma', 'data', '3036965445', 'messages.db');

const SELF = '3036965445';
const GROUP = '1001774339';
const BEGIN = '<!-- SHARED-MEMORY: BEGIN（自动生成，勿手改）-->';
const END = '<!-- SHARED-MEMORY: END -->';

// 谁值得写进共享记忆（昵称用于输出）
const PEOPLE = {
  '000000000': { name: '一只闲鱼（你的操作者）', maxLines: 3 },
  '000000000': { name: '栩', maxLines: 3 },
  '000000000': { name: '罗辑', maxLines: 3 },
  '000000000': { name: 'LANGRISSER', maxLines: 3 },
  '000000000': { name: '小鲸鱼（群里）', maxLines: 3 },
  '3795825851': { name: '画师（群主）', maxLines: 1 },
};

// 只保留最近这么多小时的内容
const WINDOW_HOURS = 12;
// 每人最多取多少条最近消息来看
const SCAN_LIMIT = 40;

function plain(segs) {
  let o = '';
  for (const s of segs || []) {
    const t = s.type, d = s.data || {};
    if (t === 'text') o += d.text;
    else if (t === 'image') o += '[图]';
    else if (t === 'face') o += '[表情]';
    else if (t === 'at') o += '@' + (d.qq || '');
    else if (t === 'reply') o += '[回复]';
  }
  return o.replace(/\s+/g, ' ').trim();
}

function ago(ts) {
  const m = Math.round((Date.now() / 1000 - ts) / 60);
  if (m < 1) return '刚刚';
  if (m < 60) return m + '分钟前';
  const h = Math.round(m / 60);
  if (h < 24) return h + '小时前';
  return Math.round(h / 24) + '天前';
}

function timeHM(ts) {
  const d = new Date(ts * 1000);
  return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
}

let db;
try {
  db = new DatabaseSync(DB, { readOnly: true });
} catch (e) {
  console.error('读不到消息库: ' + e.message);
  process.exit(1);
}

const since = Math.floor(Date.now() / 1000) - WINDOW_HOURS * 3600;
const lines = [];

// ---------- 1. 各个私聊 ----------
lines.push('【最近在跟谁聊什么】');
let anyPrivate = false;

for (const [uin, meta] of Object.entries(PEOPLE)) {
  let rows;
  try {
    rows = db.prepare(
      `select timestamp, data from messages where is_group=0 and session_id=? order by timestamp desc limit ?`
    ).all(uin, SCAN_LIMIT);
  } catch { continue; }
  const recent = rows.filter((r) => r.timestamp >= since);
  if (!recent.length) continue;

  // 取最近 2 条「对方说的」+ 最近 1 条「我说的」，拼成一句
  const theirs = [];
  let mineLast = null;
  for (const r of recent) {
    let d; try { d = JSON.parse(r.data); } catch { continue; }
    const txt = plain(d.message);
    if (!txt) continue;
    if (String(d.user_id) === SELF) { if (!mineLast) mineLast = { ts: r.timestamp, txt }; }
    else if (theirs.length < 2) theirs.push({ ts: r.timestamp, txt });
  }
  if (!theirs.length && !mineLast) continue;

  anyPrivate = true;
  lines.push(`- ${meta.name}：`);
  const picked = theirs.slice().reverse().slice(-meta.maxLines);
  for (const t of picked) {
    lines.push(`    ${timeHM(t.ts)} 他说「${t.txt.slice(0, 42)}」（${ago(t.ts)}）`);
  }
  if (mineLast) {
    lines.push(`    你最后回的是「${mineLast.txt.slice(0, 42)}」（${ago(mineLast.ts)}）`);
  }
}

if (!anyPrivate) lines.push('- （最近 12 小时没有私聊）');

// ---------- 2. 群里的近况 ----------
lines.push('');
lines.push('【群里最近】');
try {
  const rows = db.prepare(
    `select timestamp, data from messages where is_group=1 and timestamp > ? order by timestamp asc`
  ).all(since);
  const mine = rows.filter((r) => String(JSON.parse(r.data).user_id) === SELF);
  if (rows.length) {
    const last = rows.slice(-3).map((r) => {
      const d = JSON.parse(r.data);
      const nm = (d.sender && (d.sender.card || d.sender.nickname)) || d.user_id;
      const who = String(d.user_id) === SELF ? '你' : nm;
      return `${timeHM(r.timestamp)} ${who}「${plain(d.message).slice(0, 34)}」`;
    });
    lines.push(`- 近 ${WINDOW_HOURS} 小时 ${rows.length} 条，你说了 ${mine.length} 条`);
    for (const l of last) lines.push(`    ${l}`);
  } else {
    lines.push(`- 近 ${WINDOW_HOURS} 小时群里没人说话`);
  }
} catch (e) {
  lines.push('- （读群消息失败）');
}

lines.push('');
lines.push('> 这段是自动生成的。跟别人聊过什么，这里能看见一部分，别当成全部。');

const block = lines.join('\n');

// ---------- 生成「我自己总结的」（从 agent 自己的记忆长出来）----------
// 数据源：social-v2.json 里各会话的 memberImpressions / activeTopics。
// 这些是 agent 自己调 qq_memory_append 写的，所以这一节本质上是「它自己的学习成果」。
const SELF_BEGIN = '<!-- SELF-NOTES: BEGIN（自动生成，勿手改）-->';
const SELF_END = '<!-- SELF-NOTES: END -->';
const SELF_MAX_CHARS = 1500;   // 这一节最多占这么多字符，别把人格卡撑爆

function buildSelfNotes() {
  const out = [];
  let sv;
  try {
    const sp = path.join(BRIDGE_DIR, 'state', 'social-v2.json');
    sv = JSON.parse(fs.readFileSync(sp, 'utf8').replace(/^\uFEFF/, ''));
  } catch {
    return '（暂时读不到记忆）';
  }
  const convs = sv.conversations || {};

  // 群友印象：跨所有会话合并（同一个人可能既在群里也在私聊里出现）
  const impressionMap = new Map();
  let impressionTotal = 0;
  for (const c of Object.values(convs)) {
    const im = c && c.memberImpressions;
    if (!im || typeof im !== 'object') continue;
    for (const [name, v] of Object.entries(im)) {
      const traits = Array.isArray(v?.traits) ? v.traits.filter(Boolean) : [];
      if (!traits.length) continue;
      impressionTotal += traits.length;
      const cur = impressionMap.get(name) || { traits: [], count: 0 };
      for (const t of traits) if (!cur.traits.includes(t)) cur.traits.push(t);
      cur.count += Number(v?.interactionCount) || 0;
      impressionMap.set(name, cur);
    }
  }
  if (impressionMap.size) {
    out.push('【这一段人，我摸清了】');
    // 去掉 trait 里重复的人名前缀。
    // AI 写记忆时习惯把名字也写进内容（"000000000：私聊陌生人…"、
    // "罗辑会拿大肥鱼故意钓鱼…"），而外面已经加了 "- 名字："，
    // 不清理就会出现「罗辑：罗辑会拿…」这种读着别扭、还白占字符的重复。
    const stripName = (trait, name) => {
      let s = String(trait || '').trim();
      const n = String(name || '').trim();
      if (!s || !n) return s;
      if (s.startsWith(n)) {
        const rest = s.slice(n.length).replace(/^[：:，,、\s]+/, '');
        // 剥完只剩一两个字，说明名字是内容的一部分，别硬剥
        if (rest.length >= 4) s = rest;
      }
      return s;
    };
    const entries = [...impressionMap.entries()]
      .sort((a, b) => b[1].count - a[1].count)
      .slice(0, 8);
    for (const [name, v] of entries) {
      const traits = [];
      for (const raw of v.traits) {
        const s = stripName(raw, name);
        if (s && !traits.includes(s)) traits.push(s);   // 剥完可能撞车，去重
      }
      out.push(`- ${name}：${traits.slice(0, 3).join('；')}`);
    }
  }

  // 长期话题：只留还在 24 小时内的（appendMemoryV2 本来就按这个清理）
  const topicSet = new Set();
  for (const c of Object.values(convs)) {
    if (!Array.isArray(c?.activeTopics)) continue;
    for (const t of c.activeTopics) {
      const text = String(t?.text || '').trim();
      if (text && !topicSet.has(text)) topicSet.add(text);
    }
  }
  if (topicSet.size) {
    out.push('');
    out.push('【还搁着的事】');
    for (const t of [...topicSet].slice(-10)) out.push(`- ${t.slice(0, 60)}`);
  }

  if (!out.length) return '（还没有内容。多聊几次，记几次，这里就会长出来。）';
  out.push('');
  out.push('> 这些都是你自己记下来的，不是别人写的。觉得不准，就用 qq_memory_remove 删掉重记。');
  let text = out.join('\n');
  if (text.length > SELF_MAX_CHARS) text = text.slice(0, SELF_MAX_CHARS) + '\n…（太长截断了）';
  return text;
}

const selfBlock = buildSelfNotes();
const newSelfSection = `${SELF_BEGIN}\n## 十六、我自己总结的（会随你写的记忆自动更新）\n\n${selfBlock}\n${SELF_END}`;

// ---------- 写入人格卡 ----------
let role = fs.readFileSync(ROLE, 'utf8').replace(/^\uFEFF/, '');
const newSection = `${BEGIN}\n## 十四、最近跟别人聊了什么（自动同步）\n\n${block}\n${END}`;

const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
function putSection(text, begin, end, replacement) {
  if (text.includes(begin) && text.includes(end)) {
    return text.replace(new RegExp(esc(begin) + '[\\s\\S]*?' + esc(end)), replacement);
  }
  return text.trimEnd() + '\n\n' + replacement + '\n';
}

role = putSection(role, BEGIN, END, newSection);
role = putSection(role, SELF_BEGIN, SELF_END, newSelfSection);

// 保险：人格卡有硬上限（config 的 role.maxInjectChars，默认 8000），超了会被截断，
// 截断位置在末尾 —— 正好会切掉这两节自动内容。所以超了要报警。
const HARD_LIMIT = 10000;
if (role.length > HARD_LIMIT - 100) {
  console.warn(`⚠ 人格卡 ${role.length} 字符，接近上限 ${HARD_LIMIT}，需要精简静态部分`);
}

// 按编码检查（PowerShell 那边不是这个文件；这里是纯 UTF-8，不带 BOM）
if (process.argv.includes('--dry')) {
  console.log(newSection);
  console.log('\n---');
  console.log(newSelfSection);
  console.log('\n--- 试运行，未写入。新人格卡长度: ' + role.length + ' 字符 ---');
} else {
  fs.writeFileSync(ROLE, role, 'utf8');
  console.log('已写入人格卡，长度 ' + role.length + ' 字符');
}
