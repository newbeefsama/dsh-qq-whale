# -*- coding: utf-8 -*-
"""annotate-stickers.py —— 给收藏表情写「这张图是什么情绪、适合什么场景」

为什么要 OCR + VLM 两步，而不是只用 VLM：
  QQ 表情包大量是**文字梗图**。实测 qwen2.5vl:3b 对
    「*阴暗的爬行」→ 说成「一个人装死」（完全没读到字）
    「武装夺取政权」→ 只认出「群主」，主文案漏了，还把夺权姿势读成「困惑无奈」
  认不出字 = 梗理解反 = 标了等于没标。

  所以：RapidOCR（专门的中文 OCR，CPU 就能跑）先把字抠准，
  再把字作为提示喂给 VLM —— 视觉模型**看图不行、给它字就能推理**。

用法：
  python annotate-stickers.py [--dry] [--limit N] [--model qwen2.5vl:3b]
"""
import json
import os
import sys
import base64
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(HERE, '..', '..', 'qq-bridge', 'state')
STICKERS = os.path.join(STATE, 'stickers.json')
CACHE = os.path.join(STATE, 'sticker-cache')
OLLAMA = 'http://127.0.0.1:11434'

PROMPT = """这是一张 QQ 聊天里用的表情包。{text_hint}

请用简体中文输出一个 JSON（不要任何其它文字）：

1. look：画面上具体是什么。是猫/企鹅/真人/熊猫头/简笔画？什么表情、什么动作、什么姿态？
   如果上面给了文字，把关键文字自然融进描述里。
   **不允许**写"一个表情包""一个人物"这种空话。
2. emotion：这张图在聊天里传达的情绪，1~4 个词，用顿号分隔（如：嘲讽、撒娇、无语、得意）。
3. scene：这张图最典型的一次用法。必须针对这张图本身，写清"对方说了什么 → 发这张图"。
   不要写通用套话。

格式：{{"look":"...","emotion":"...","scene":"..."}}"""


def load_stickers():
    with open(STICKERS, 'r', encoding='utf-8-sig') as f:
        return json.load(f)


def save_stickers(arr):
    tmp = STICKERS + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(arr, f, ensure_ascii=False, indent=2)
    os.replace(tmp, STICKERS)


def ensure_image(entry):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, entry['md5'] + '.img')
    if os.path.exists(path) and os.path.getsize(path) > 200:
        return path
    with urllib.request.urlopen(entry['url'], timeout=30) as r:
        data = r.read()
    with open(path, 'wb') as f:
        f.write(data)
    return path


def ocr_text(ocr, path):
    try:
        result, _ = ocr(path)
        if not result:
            return ''
        # result: [[box, text, score], ...] 按阅读顺序已经排好
        parts = [str(item[1]).strip() for item in result if float(item[2]) >= 0.4]
        text = ' '.join(p for p in parts if p)
        return text[:120]
    except Exception:
        return ''


def ask_vlm(model, path, text_hint):
    with open(path, 'rb') as f:
        b64 = base64.b64encode(f.read()).decode('ascii')
    payload = {
        'model': model,
        'prompt': PROMPT.format(text_hint=text_hint),
        'images': [b64],
        'stream': False,
        'think': False,
        'options': {'temperature': 0.2, 'num_predict': 300},
    }
    req = urllib.request.Request(
        OLLAMA + '/api/generate',
        data=json.dumps(payload).encode('utf-8'),
        headers={'Content-Type': 'application/json'},
        method='POST',
    )
    with urllib.request.urlopen(req, timeout=180) as r:
        body = json.loads(r.read().decode('utf-8'))
    raw = body.get('response', '')
    i, j = raw.find('{'), raw.rfind('}')
    if i < 0 or j <= i:
        raise ValueError('模型没返回 JSON：' + raw[:80])
    return json.loads(raw[i:j + 1]), len(payload['images'][0])


def main():
    args = sys.argv[1:]
    dry = '--dry' in args
    limit = 0
    if '--limit' in args:
        k = args.index('--limit')
        if k + 1 < len(args):
            limit = int(args[k + 1])
    model = 'qwen2.5vl:3b'
    if '--model' in args:
        k = args.index('--model')
        if k + 1 < len(args):
            model = args[k + 1]

    arr = load_stickers()
    todo = [e for e in arr if e.get('url') and not str(e.get('localNote') or '').strip()]
    targets = todo[:limit] if limit else todo
    print('总数 %d，已有笔记 %d，本次处理 %d' % (len(arr), len(arr) - len(todo), len(targets)))
    print('模型 %s%s' % (model, '（dry run，不写回）' if dry else ''))

    try:
        from rapidocr_onnxruntime import RapidOCR
        ocr = RapidOCR()
        print('OCR 已就绪')
    except Exception as e:
        ocr = None
        print('⚠ OCR 不可用（%s），只靠视觉模型' % str(e)[:80])

    ok = fail = 0
    for idx, e in enumerate(targets):
        t0 = time.time()
        md5 = e['md5'][:8]
        try:
            path = ensure_image(e)
            text = ocr_text(ocr, path) if ocr else ''
            text_hint = ('图上识别出的文字：「%s」—— 这是关键信息，请结合它理解这张图。' % text) if text else '（图上没有文字）'
            r, _ = ask_vlm(model, path, text_hint)
            emos = [x.strip() for x in str(r.get('emotion', '')).replace(',', '、').replace('/', '、').split('、') if x.strip()][:4]
            look = str(r.get('look', '')).strip()
            scene = str(r.get('scene', '')).strip()
            note = ('[视觉]%s｜%s%s' % ('/'.join(emos) or '?', look, ('｜' + scene) if scene else ''))[:200]
            print('  [%d/%d] %s  %.1fs%s' % (idx + 1, len(targets), md5, time.time() - t0, ('  OCR:' + text[:20]) if text else '  (无文字)'))
            print('      ' + note)
            if not dry:
                e['localNote'] = note
                e['tags'] = emos[:6]
                e['updatedAt'] = time.strftime('%Y-%m-%dT%H:%M:%S+08:00')
                if (idx + 1) % 5 == 0:
                    save_stickers(arr)
            ok += 1
        except Exception as ex:
            print('  [%d/%d] %s  ❌ %s' % (idx + 1, len(targets), md5, str(ex)[:100]))
            fail += 1
    if not dry:
        save_stickers(arr)
    print('\n完成：成功 %d，失败 %d%s' % (ok, fail, '（未写回）' if dry else ''))
    print('（需要重启桥接让它重新读 stickers.json）')


if __name__ == '__main__':
    main()