// friend-accept.cjs —— 自动加好友。
//
// 为什么要这个：QQ 好友申请是「事件」，不是「查询」。
//   - 有 set_friend_add_request（同意/拒绝，按 flag）
//   - 没有 get_friend_add_request（查不到待处理列表）
// 所以只能挂 WS 实时接收，收到就处理，错过就没了。
//
// 策略（2026-10-21 定）：
//   1. 好友申请 → 一律同意（QQ 侧有反垃圾，且 bot 只会和白名单里的人说话，
//      加了不等于会聊，风险可控）
//   2. 同意后给 owner 发一条私聊，告诉他加了谁、验证消息是什么
//      —— 加谁进来是 owner 该知道的事，不该悄悄发生
//   3. 群邀请 → 只记录，不同意（不擅自进群）
//
// 用法：node friend-accept.cjs [--notify <ownerQQ>]
//   默认 owner 从 qq-bridge/config.json 的 ownerQQ 读

const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');

const WS_URL = 'ws://127.0.0.1:3001/';
const WS_TOKEN = '-LtcaV0dlVufj8L73ziHmxFJ8NclsAiVTQpz8rXKAvU';
const HTTP_PORT = 3000;
const HTTP_TOKEN = '_eT4GmIxYAhAvS_kUOcXOlhkSqO_UAiTJBXW2Nmg8-Q';
const SELF = process.env.QQ_SELF_UIN || '';   // 机器人自己的 QQ 号，跑之前设环境变量或改这里

const LOG = path.join(__dirname, '_friend.log');

// owner QQ：命令行参数优先，其次读桥接配置
let OWNER = '';
const argIdx = process.argv.indexOf('--notify');
if (argIdx > 0 && process.argv[argIdx + 1]) {
  OWNER = String(process.argv[argIdx + 1]);
} else {
  try {
    const cfgPath = path.join(__dirname, '..', '..', 'qq-bridge', 'config.json');
    const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8').replace(/^\uFEFF/, ''));
    if (cfg.ownerQQ) OWNER = String(cfg.ownerQQ);
  } catch {}
}

function note(msg) {
  const line = `${new Date().toISOString().replace('T', ' ').slice(0, 19)}  ${msg}`;
  try { fs.appendFileSync(LOG, line + '\n', 'utf8'); } catch {}
  console.log(line);
}

function onebot(action, params) {
  return new Promise((resolve) => {
    const body = Buffer.from(JSON.stringify(params), 'utf8');
    const req = http.request(
      {
        host: '127.0.0.1', port: HTTP_PORT, path: '/' + action, method: 'POST', agent: false,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': body.length,
          Authorization: 'Bearer ' + HTTP_TOKEN,
        },
      },
      (res) => {
        const c = [];
        res.on('data', (d) => c.push(d));
        res.on('end', () => {
          try { resolve(JSON.parse(Buffer.concat(c).toString('utf8'))); }
          catch { resolve({ status: 'failed', wording: 'response parse failed' }); }
        });
      }
    );
    req.on('error', (e) => resolve({ status: 'failed', wording: e.message }));
    req.setTimeout(15000, () => req.destroy(new Error('timeout')));
    req.write(body);
    req.end();
  });
}

// 给 owner 汇报（私聊）。失败不影响主流程。
async function tellOwner(text) {
  if (!OWNER) return;
  try { await onebot('send_private_msg', { user_id: Number(OWNER), message: [{ type: 'text', data: { text } }] }); }
  catch {}
}

// ── 把新好友加进私聊白名单（2026-10-24 加）──────────────────────────────
// 为什么需要：桥接只会回 allow.private 里的人，加了好友但不在白名单 = 加了也白加。
// 做法：走桥接控制台的 /api/whitelist，可以在运行时生效，不用重启桥接。
//   GET  /api/whitelist  -> { allow: { private: [...], groups: [...] } }
//   POST /api/whitelist  { allow: { private: [...], groups: [...] } }
const BRIDGE_DIR = path.join(__dirname, '..', '..', 'qq-bridge');

function consoleToken() {
  try { return fs.readFileSync(path.join(BRIDGE_DIR, 'state', 'console-token'), 'utf8').trim(); } catch { return ''; }
}

function bridgeCall(method, apiPath, body) {
  return new Promise((resolve) => {
    const tok = consoleToken();
    if (!tok) { resolve({ ok: false, error: '读不到 console-token' }); return; }
    const data = body ? Buffer.from(JSON.stringify(body), 'utf8') : null;
    const headers = { 'x-console-token': tok, Authorization: 'Bearer ' + tok };
    if (data) { headers['Content-Type'] = 'application/json'; headers['Content-Length'] = data.length; }
    const req = http.request(
      { host: '127.0.0.1', port: 3100, path: apiPath, method, agent: false, headers },
      (res) => {
        const c = [];
        res.on('data', (x) => c.push(x));
        res.on('end', () => {
          try { resolve(JSON.parse(Buffer.concat(c).toString('utf8'))); }
          catch { resolve({ ok: false, error: '响应解析失败' }); }
        });
      }
    );
    req.on('error', (e) => resolve({ ok: false, error: e.message }));
    req.setTimeout(15000, () => req.destroy(new Error('timeout')));
    if (data) req.write(data);
    req.end();
  });
}

async function addToPrivateWhitelist(uin) {
  const id = Number(uin);
  if (!Number.isFinite(id) || id <= 0) return { ok: false, error: 'QQ 号无效' };
  try {
    const cur = await bridgeCall('GET', '/api/whitelist');
    if (!cur || !cur.allow) return { ok: false, error: '取不到当前白名单' };
    const list = Array.isArray(cur.allow.private) ? cur.allow.private.map(Number) : [];
    if (list.includes(id)) {
      note(`  ${id} 已在白名单里，不重复添加`);
      return { ok: true, count: list.length, already: true };
    }
    list.push(id);
    const res = await bridgeCall('POST', '/api/whitelist', {
      allow: { private: list, groups: Array.isArray(cur.allow.groups) ? cur.allow.groups : [] }
    });
    if (!res || res.ok !== true) return { ok: false, error: (res && res.error) || '桥接返回失败' };
    const n = Array.isArray(res.allow?.private) ? res.allow.private.length : list.length;
    note(`  ✓ 已把 ${id} 加入私聊白名单（现有 ${n} 个）`);
    return { ok: true, count: n };
  } catch (e) {
    return { ok: false, error: String(e && e.message ? e.message : e) };
  }
}

function connect() {
  const ws = new WebSocket(WS_URL, { headers: { Authorization: `Bearer ${WS_TOKEN}` } });

  ws.addEventListener('open', () => note('WS 已连接，开始监听好友申请'));

  ws.addEventListener('message', async (ev) => {
    let d;
    try { d = JSON.parse(typeof ev.data === 'string' ? ev.data : ev.data.toString()); }
    catch { return; }

    if (d.post_type !== 'request') return;

    const from = String(d.user_id ?? '');
    const comment = String(d.comment ?? '').slice(0, 80);

    // 好友申请
    if (d.request_type === 'friend') {
      note(`好友申请  from=${from}  「${comment}」  flag=${String(d.flag).slice(0, 20)}…`);
      const r = await onebot('set_friend_add_request', { flag: d.flag, approve: true });
      const ok = r && r.status === 'ok' && r.retcode === 0;
      note(ok ? `  ✓ 已同意 ${from}` : `  ✗ 同意失败 ${JSON.stringify(r).slice(0, 160)}`);
      if (!ok) {
        await tellOwner(`[自动加好友] ${from} 的申请同意失败了：${r && r.wording ? r.wording : '未知'}\n验证消息：「${comment}」`);
        return;
      }
      // 同意成功后直接加白名单，否则加了也聊不了（桥接只回白名单里的人）
      const wl = await addToPrivateWhitelist(from);
      await tellOwner(
        `[自动加好友] 已同意 ${from}。验证消息：「${comment || '(无)'}」\n` +
          (wl.ok
            ? `已自动加入白名单（现在共 ${wl.count} 个私聊）。他发消息鲸鱼娘就会回。`
            : `⚠ 加白名单失败：${wl.error}\n需要手动去 config.json 的 allow.private 加上这个号。`)
      );
      return;
    }

    // 群邀请 / 加群请求：只记录，不擅自处理
    if (d.request_type === 'group') {
      note(`群请求  type=${d.sub_type}  group=${d.group_id}  from=${from}  「${comment}」——只记录，不自动处理`);
      await tellOwner(`[群请求] 群 ${d.group_id}（${d.sub_type}），来自 ${from}，验证消息：「${comment}」。我没自动处理。`);
      return;
    }
  });

  ws.addEventListener('close', () => {
    note('WS 断开，5 秒后重连');
    setTimeout(connect, 5000);
  });
  ws.addEventListener('error', () => { /* close 会跟着来 */ });
}

note(`启动 friend-accept（owner=${OWNER || '未设置'}）`);
connect();
