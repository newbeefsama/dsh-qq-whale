#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""voice-transcribe.py —— 把一条 QQ 语音（SILK）转成文字。

背景（2026-10-22）：
    桥接对语音消息只做 `case 'record': out.push('[语音]')` —— 正文全丢，
    所以机器人"听得见有人发了语音，但不知道说了什么"。

链路（全部本地，不联网）：
    1. 桥接把语音直链下载成 .silk 临时文件
    2. 本脚本用 pysilk 解码成 16kHz 单声道 PCM，写成 wav
    3. 调 Tulpa 自带的 whisper-cli + ggml-small 模型转写
    4. 输出 JSON：{ok, text, ms, error}

为什么不用 ffmpeg：
    QQ 语音是 SILK_V3（文件头写着），ffmpeg 根本不解这个格式。
    Tulpa 的 Python 运行时里已经装了 pysilk，直接解码最省事。

用法：
    python voice-transcribe.py <输入文件> [--lang zh] [--json]
    输出到 stdout 的 JSON：{"ok":true,"text":"...","backend":"whisper.cpp","ms":1234}

依赖（都在 Tulpa 里）：
    runtime/python.exe
    runtime/Lib/site-packages/pysilk
    tools/whispercpp/Release/whisper-cli.exe
    _工具/asr/ggml-small-q5_1.bin
"""
import io
import json
import os
import subprocess
import sys
import tempfile
import time
import wave
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent                      # qq群聊助手
TULPA = WORKSPACE / 'Tulpa'

# ── 为什么全部用「相对路径 + 切工作目录」────────────────────────────────
# 工作区路径含中文（"惠普"、"群聊助手"），而：
#   · whisper-cli 解析非 ASCII 绝对路径会直接崩（实测退出码 0xC0000409）
#   · DSH 的文件沙箱只允许子进程在工作区内读写（C:\Users\Public 之类写不进去）
#   · 8.3 短路径也帮不上：中文段会原样保留（C:\Users\<你>\...）
# 解法：把模型放进 whisper 的 Release 目录，临时 wav 放它的 _tmp 子目录，
#       cwd 切到 Release，所有参数都是纯 ASCII 相对路径。实测可行。
WHISPER_DIR = TULPA / 'tools' / 'whispercpp' / 'Release'
WHISPER_EXE = WHISPER_DIR / 'whisper-cli.exe'
MODEL = WHISPER_DIR / 'ggml-small.bin'          # 就是 ggml-small-q5_1.bin 的副本
TMP_DIR = WHISPER_DIR / '_tmp'

SAMPLE_RATE = 16000

# 输出必须是 UTF-8：父进程按 UTF-8 读 stdout，而 Windows 默认 GBK，
# 一旦错误信息里带替换字符就会 UnicodeEncodeError 把整个脚本搞挂。
try:
    sys.stdout.reconfigure(encoding='utf-8')
except Exception:
    pass


def fail(msg):
    print(json.dumps({'ok': False, 'error': str(msg)[:300]}, ensure_ascii=False))
    sys.exit(0)


def read_audio(path: Path):
    """读入音频字节。SILK 和已经是 16k wav 的两种情况都处理。"""
    raw = path.read_bytes()
    if len(raw) < 16:
        raise ValueError('音频文件太小')
    return raw


def decode_to_wav(raw: bytes, out_path: Path) -> str:
    """SILK -> 16kHz 单声道 wav。返回实际用的 codec 名。"""
    # QQ 语音文件头形如 "\x02#!SILK_V3"，个别版本前面还有 0x02 前缀
    if b'SILK' in raw[:16]:
        try:
            import pysilk
        except ImportError:
            raise RuntimeError('pysilk 未安装（应在 Tulpa\\runtime 里）')
        pcm = pysilk.decode(raw, sample_rate=SAMPLE_RATE)
        with wave.open(str(out_path), 'wb') as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SAMPLE_RATE)
            w.writeframes(pcm)
        return 'silk'

    # 已经是 wav：检查是否 16k 单声道
    try:
        with wave.open(io.BytesIO(raw)) as w:
            ch, sw, sr = w.getnchannels(), w.getsampwidth(), w.getframerate()
        if (ch, sw, sr) == (1, 2, SAMPLE_RATE):
            out_path.write_bytes(raw)
            return 'wav'
        raise ValueError(f'不支持的 wav 参数 {ch}ch/{sw}byte/{sr}Hz（只支持 16k 单声道）')
    except wave.Error:
        raise ValueError('既不是 SILK 也不是 wav')


def transcribe(wav_path: Path, lang: str):
    """调 whisper-cli。注意全部用相对路径、cwd 切到 Release 目录（见文件头说明）。"""
    if not WHISPER_EXE.is_file():
        raise RuntimeError(f'找不到 whisper-cli: {WHISPER_EXE}')
    if not MODEL.is_file():
        raise RuntimeError(f'找不到模型: {MODEL}（应放在 {WHISPER_DIR}）')
    try:
        rel_wav = wav_path.relative_to(WHISPER_DIR).as_posix()
    except ValueError:
        raise RuntimeError('wav 必须放在 whisper Release 目录下（相对路径限制）')
    # -nt: 不要时间戳；-l 语言；-t 线程数；--no-prints 静音初始化日志
    # 注意：exe 必须给**绝对路径**——Windows 下 subprocess 不会按 cwd 去解析相对程序名（实测 FileNotFoundError）；
    #       而 -m/-f 两个参数必须是**相对路径**，因为 whisper-cli 自己解析不了含中文的绝对路径。
    #       所以这里 exe 绝对、参数相对、cwd 切到 Release 目录，三者配合才成立。
    cmd = [
        str(WHISPER_EXE),
        '-m', 'ggml-small.bin',
        '-f', rel_wav,
        '-l', lang,
        '-nt',
        '-t', '4',
        '--no-prints',
    ]
    # whisper 听中文时经常吐繁体字，给一句简体提示词能明显纠正（whisper.cpp 的 --prompt）
    if lang.startswith('zh'):
        cmd += ['--prompt', '以下是普通话的对话，请用简体中文转写。']
    proc = subprocess.run(cmd, cwd=str(WHISPER_DIR), capture_output=True, timeout=180)
    if proc.returncode != 0:
        tail = (proc.stderr or b'').decode('utf-8', 'replace')[-300:]
        raise RuntimeError(f'whisper-cli 退出码 {proc.returncode}: {tail}')
    text = proc.stdout.decode('utf-8', 'replace')
    # 去掉 [BLANK_AUDIO]、(掌声) 这类非语音标注和多余空白
    lines = []
    for ln in text.splitlines():
        s = ln.strip()
        if not s:
            continue
        if s.startswith('[') and s.endswith(']'):
            continue
        lines.append(s)
    return ' '.join(lines).strip()


def main():
    if len(sys.argv) < 2:
        fail('用法: voice-transcribe.py <音频文件> [--lang zh]')
    src = Path(sys.argv[1])
    lang = 'zh'
    if '--lang' in sys.argv:
        i = sys.argv.index('--lang')
        if i + 1 < len(sys.argv):
            lang = sys.argv[i + 1]
    if not src.is_file():
        fail(f'文件不存在: {src}')

    t0 = time.time()
    try:
        raw = read_audio(src)
        # 临时 wav 必须放 whisper Release 目录下（相对路径限制）
        TMP_DIR.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='v-', dir=str(TMP_DIR)) as td:
            wav = Path(td) / 'a.wav'
            codec = decode_to_wav(raw, wav)
            text = transcribe(wav, lang)
        ms = int((time.time() - t0) * 1000)
        if not text:
            print(json.dumps({'ok': False, 'error': '没识别出内容（可能是静音/噪音）', 'codec': codec, 'ms': ms},
                             ensure_ascii=False))
            return
        print(json.dumps({'ok': True, 'text': text, 'codec': codec, 'backend': 'whisper.cpp',
                          'model': MODEL.name, 'ms': ms}, ensure_ascii=False))
    except Exception as e:  # noqa: BLE001  —— 任何失败都要给桥接一个可读结果
        import traceback
        tb = traceback.format_exc().strip().splitlines()
        # 给最后两帧，够定位又不至于把 stdout 灌爆
        detail = ' | '.join(x.strip() for x in tb[-3:])
        print(json.dumps({'ok': False, 'error': str(e)[:200], 'where': detail[:400],
                          'ms': int((time.time() - t0) * 1000)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
