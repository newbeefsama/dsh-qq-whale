// auto-rotate.cjs —— 上下文防膨胀：会话跑太多轮就换一个新的。
//
// 问题（2026-10-22 实测）：
//   群会话跑到 38 轮时上下文涨到 37 万 token，之后的 turn 只输出 step1 就再没下文，
//   表现就是「人还在群里，但怎么叫都不说话」。重启桥接、重新唤醒都没用，
//   只有换一个全新的 DSH 会话才恢复。
//
// 为什么不直接在桥接里判 turn/end：
//   试过在 recordSessionUsage 里数 turn/end，计数一直不涨（事件没走到那）。
//   这里改成从 token-usage.jsonl 反推 —— 那份文件每条 turn 记录都带 sid + turn，
//   数「当前 sid 下有几个不同的 turn」就等于「这个会话跑了多少轮」，稳且不需要改桥接事件流。
//
// 轮换时桥接会先攒一份「交接摘要」（最近对话 + 还没了结的事 + 人物印象），
// 新会话第一轮唤醒注入一次 —— 忘掉远期细节，保留最近细节。
//
// 用法：
//   node auto-rotate.cjs            检查一次，超了就轮换
//   node auto-rotate.cjs --dry      只看不轮换
//   node auto-rotate.cjs --threshold 30

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');

const WS_DIR = path.join(__dirname, '..', '..', 'qq-bridge');
const STATE = path.join(WS_DIR, 'state');
const USAGE = path.join(STATE, 'token-usage.jsonl');
const SESSIONS = path.join(STATE, 'sessions.json');
const CONSOLE_TOKEN = path.join(STATE, 'console-token');
const LOG = path.join(__dirname, '_autorotate.log');

const DEFAULT_THRESHOLD = 25;

function argValue(name, fallback) {
  const i = process.argv.indexOf(name);
  if (i > 0 && process.argv[i + 1]) return Number(process.argv[i + 1]) || fallback;
  return fallback;
}
const THRESHOLD = argValue('--threshold', DEFAULT_THRESHOLD);
const DRY = process.argv.includes('--dry');

function note(msg) {
  const line = `${new Date().toISOString().replace('T', ' ').slice(0, 19)}  ${msg}`;
  try { fs.appendFileSync(LOG, line + '\n', 'utf8'); } catch {}
  console.log(line);
}

function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^\uFEFF/, '')); } catch { return fallback; }
}

function consoleToken() {
  try { return fs.readFileSync(CONSOLE_TOKEN, 'utf8').trim(); } catch { return ''; }
}

function rotate(key) {
  return new Promise((resolve) => {
    const tok = consoleToken();
    const body = Buffer.from(JSON.stringify({ key }), 'utf8');
    const req = http.request({
      host: '127.0.0.1', port: 3100, path: '/api/socialV2/rotate-session', method: 'POST', agent: false,
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': body.length,
        'x-console-token': tok,
        Authorization: 'Bearer ' + tok,
      },
    }, (res) => {
      const c = [];
      res.on('data', (d) => c.push(d));
      res.on('end', () => resolve(Buffer.concat(c).toString('utf8')));
    });
    req.on('error', (e) => resolve('ERR ' + e.message));
    req.setTimeout(20000, () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

(async () => {
  const sessions = readJson(SESSIONS, {}).sessions || {};
  if (!Object.keys(sessions).length) { note('没有会话映射，跳过'); return; }

  // 统计每个 sid 下出现过的不同 turn 编号
  const turnsBySid = new Map();  // sid -> Set(turn)
  let lines = [];
  try { lines = fs.readFileSync(USAGE, 'utf8').trim().split('\n').filter(Boolean); } catch {}
  // 只扫最后 4000 条，够覆盖当前会话
  for (const l of lines.slice(-4000)) {
    let j; try { j = JSON.parse(l); } catch { continue; }
    if (j.k !== 'turn' || !j.sid || j.turn === undefined) continue;
    let set = turnsBySid.get(j.sid);
    if (!set) { set = new Set(); turnsBySid.set(j.sid, set); }
    set.add(j.turn);
  }

  const report = [];
  for (const [key, sid] of Object.entries(sessions)) {
    const n = turnsBySid.get(sid)?.size ?? 0;
    report.push({ key, sid, turns: n });
  }
  report.sort((a, b) => b.turns - a.turns);

  let rotated = 0;
  for (const r of report) {
    const flag = r.turns >= THRESHOLD ? '  ← 该轮换了' : '';
    note(`${r.key}  当前会话跑了 ${r.turns} 轮 / 阈值 ${THRESHOLD}${flag}`);
    if (r.turns >= THRESHOLD) {
      if (DRY) { note(`  [dry] 不轮换 ${r.key}`); continue; }
      const res = await rotate(r.key);
      let ok = false, handoff = 0;
      try { const j = JSON.parse(res); ok = j.ok === true; handoff = j.handoffChars || 0; } catch {}
      note(ok ? `  ✓ 已轮换 ${r.key}（交接摘要 ${handoff} 字，记忆保留）` : `  ✗ 轮换失败 ${r.key}: ${String(res).slice(0, 120)}`);
      if (ok) rotated += 1;
    }
  }

  if (!rotated && !DRY) note('无需轮换');
})();
