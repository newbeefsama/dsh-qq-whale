#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
看一个视频：字幕/转写 + 抽帧，看完把视频删掉。

设计（2026-10-25 按操作者要求「A+B 混合，看完就删」）：

  A 路线（内容）：
      有字幕 → 直接拿字幕（含自动生成）
      没字幕 → 抽音频 → whisper.cpp 本地转写
  B 路线（画面）：
      ffmpeg 均匀抽 N 帧 JPEG

  最后：删掉下载的视频和音频，只留帧（调用方读完会再删帧）。
        —— 因为视频动辄几十上百 MB，留一晚就能吃满磁盘。

用法：
  python video-watch.py <url> [--frames 8] [--max-mb 80] [--max-duration 900]

输出：一行 JSON 到 stdout，供 MCP 服务端解析。
出错时也是 JSON：{"ok": false, "error": "...", "where": "..."}

安全：
  - 只接受 http/https
  - 解析域名后拦掉内网/回环/保留地址（防 SSRF）
  - 大小上限、时长上限
"""

import sys
import os
import json
import time
import shutil
import socket
import ipaddress
import subprocess
import tempfile
import re
from pathlib import Path
from urllib.parse import urlparse

START = time.time()

# ── 路径常量 ────────────────────────────────────────────────────────────
HELPER_ROOT = Path(__file__).resolve().parent.parent          # qq群聊助手
TOOLS_DIR = HELPER_ROOT / '_工具'
ASR_DIR = TOOLS_DIR / 'asr'
WHISPER_DIR = HELPER_ROOT / 'Tulpa' / 'tools' / 'whispercpp' / 'Release'
WHISPER_EXE = WHISPER_DIR / 'whisper-cli.exe'
WHISPER_MODEL = WHISPER_DIR / 'ggml-small.bin'
FFMPEG = (HELPER_ROOT / 'Tulpa' / 'runtime' / 'Lib' / 'site-packages'
          / 'imageio_ffmpeg' / 'binaries' / 'ffmpeg-win-x86_64-v7.1.exe')

SAMPLE_RATE = 16000
TRANSCRIPT_MAX_CHARS = 4000
DESC_MAX_CHARS = 600
TRANSCRIBE_MAX_SECONDS = 600      # 超过 10 分钟只转前 10 分钟


def out(payload):
    """输出结果并退出。"""
    payload.setdefault('ms', int((time.time() - START) * 1000))
    sys.stdout.write(json.dumps(payload, ensure_ascii=False))
    sys.stdout.write('\n')
    sys.stdout.flush()
    sys.exit(0 if payload.get('ok') else 1)


def fail(error, where='', **extra):
    out({'ok': False, 'error': str(error)[:600], 'where': where, **extra})


# ── SSRF 防护 ───────────────────────────────────────────────────────────
def assert_safe_url(url: str):
    """只允许公网 http(https)，拦掉内网/回环/链路本地等。"""
    try:
        p = urlparse(url)
    except Exception as e:
        fail(f'URL 解析失败: {e}', 'assert_safe_url')
    if p.scheme not in ('http', 'https'):
        fail(f'只支持 http/https，收到 {p.scheme}', 'assert_safe_url')
    host = p.hostname
    if not host:
        fail('URL 里没有主机名', 'assert_safe_url')
    try:
        infos = socket.getaddrinfo(host, None)
    except Exception as e:
        fail(f'域名解析失败: {e}', 'assert_safe_url')
    for info in infos:
        ip = info[4][0]
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            continue
        if (addr.is_private or addr.is_loopback or addr.is_link_local
                or addr.is_reserved or addr.is_multicast or addr.is_unspecified):
            fail(f'拒绝访问内网地址: {host} -> {ip}', 'assert_safe_url')


# ── yt-dlp ─────────────────────────────────────────────────────────────
def run(cmd, cwd=None, timeout=300):
    """跑子进程，返回 (ok, stdout, stderr)。"""
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, timeout=timeout)
        return r.returncode == 0, r.stdout.decode('utf-8', 'ignore'), r.stderr.decode('utf-8', 'ignore')
    except subprocess.TimeoutExpired:
        return False, '', f'超时（{timeout}s）'
    except Exception as e:
        return False, '', str(e)


def pick_python():
    """找带 yt_dlp 的 Python：优先系统 Python312，再退回当前解释器。"""
    candidates = [
        Path(os.environ.get('LOCALAPPDATA', '')) / 'Programs' / 'Python' / 'Python312' / 'python.exe',
        Path(sys.executable),
    ]
    for c in candidates:
        if not c.exists():
            continue
        ok, _, _ = run([str(c), '-c', 'import yt_dlp'], timeout=30)
        if ok:
            return c
    return Path(sys.executable)


def fetch_info_and_media(url, workdir: Path, max_mb: int, max_duration: int):
    """用 yt-dlp 取元信息 + 字幕 + 视频。返回 dict。"""
    py = pick_python()
    # 1) 先只取元信息（不下载），用来判断时长/大小
    ok, stdout, stderr = run([
        str(py), '-m', 'yt_dlp',
        '--dump-single-json', '--no-playlist', '--no-warnings',
        '--socket-timeout', '20', '--retries', '2',
        url,
    ], timeout=90)
    if not ok:
        fail(f'取视频信息失败: {stderr.strip()[:300]}', 'yt_dlp.info')
    try:
        info = json.loads(stdout)
    except Exception as e:
        fail(f'信息解析失败: {e}', 'yt_dlp.info')

    duration = int(info.get('duration') or 0)
    title = str(info.get('title') or '')[:200]
    uploader = str(info.get('uploader') or info.get('channel') or '')[:100]
    desc = str(info.get('description') or '')[:DESC_MAX_CHARS]

    if duration and duration > max_duration:
        fail(f'视频太长（{duration}s > {max_duration}s），不看了', 'yt_dlp.duration',
             title=title, duration=duration)

    # 2) 下载：字幕 + 低清视频（限制分辨率，省流量）
    has_subs = bool(info.get('subtitles')) or bool(info.get('automatic_captions'))
    out_tpl = str(workdir / 'v.%(ext)s')
    cmd = [
        str(py), '-m', 'yt_dlp',
        '--no-playlist', '--no-warnings', '--no-progress',
        '--socket-timeout', '20', '--retries', '2',
        '--max-filesize', f'{max_mb}M',
        # 必须显式告诉 yt-dlp ffmpeg 在哪。
        # 不指定时它报 "ffmpeg is not installed"，于是把音视频分成两个文件下载
        # （v.f100023.mp4 + v.f30280.m4a），而后面按 v.mp4 找就找不到 ——
        # 表现为「下载成功」但抽帧 0 张、转写为空。
        # 注意：这个 exe 名字带版本号，所以要给**完整文件路径**；
        # 给目录的话 yt-dlp 只会去找目录里的 ffmpeg.exe。
        '--ffmpeg-location', str(FFMPEG),
        '-f', 'bv*[height<=480]+ba/b[height<=480]/b',
        '--merge-output-format', 'mp4',
        '-o', out_tpl,
    ]
    if has_subs:
        cmd += ['--write-subs', '--write-auto-subs', '--sub-langs',
                'zh.*,zh-Hans,zh-CN,en.*', '--convert-subs', 'srt']
    cmd.append(url)

    ok, _, stderr = run(cmd, timeout=420)
    if not ok:
        fail(f'下载失败: {stderr.strip()[:300]}', 'yt_dlp.download', title=title)

    # 3) 找下载到的文件
    video = None
    for ext in ('mp4', 'mkv', 'webm', 'flv'):
        cand = workdir / f'v.{ext}'
        if cand.exists() and cand.stat().st_size > 0:
            video = cand
            break
    sub_files = sorted(workdir.glob('v*.srt')) + sorted(workdir.glob('v*.vtt'))
    size_mb = round((video.stat().st_size / 1024 / 1024), 1) if video else 0

    # 找不到合并后的视频就明确报错，别假装成功。
    # （踩过：yt-dlp 因为找不到 ffmpeg 把音视频分开下，脚本没报错，
    #   返回 ok=true 但抽帧 0、转写空，调用方以为看过了。）
    if video is None:
        leftovers = [p.name for p in workdir.iterdir() if p.is_file()]
        fail(f'下载后找不到视频文件（可能是音视频没合并成功）。目录里有：{", ".join(leftovers) or "空"}',
             'yt_dlp.no_video', title=title)

    return {
        'title': title,
        'uploader': uploader,
        'duration': duration,
        'desc': desc,
        'video': video,
        'sub_files': sub_files,
        'size_mb': size_mb,
        'has_subs': has_subs,
    }


def probe_duration(video: Path) -> int:
    """用 ffmpeg 读真实时长（yt-dlp 对直链 mp4 常常给不出 duration）。"""
    try:
        r = subprocess.run([str(FFMPEG), '-i', str(video)],
                           capture_output=True, timeout=60)
        text = r.stderr.decode('utf-8', 'ignore')
        m = re.search(r'Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)', text)
        if m:
            h, mi, s = int(m.group(1)), int(m.group(2)), float(m.group(3))
            return int(h * 3600 + mi * 60 + s)
    except Exception:
        pass
    return 0


def srt_to_text(path: Path) -> str:
    """SRT/VTT → 纯文本（去序号、去时间轴、去重复行）。"""
    try:
        raw = path.read_text(encoding='utf-8', errors='ignore')
    except Exception:
        return ''
    lines = []
    for line in raw.splitlines():
        s = line.strip()
        if not s:
            continue
        if re.fullmatch(r'\d+', s):
            continue
        if '-->' in s:
            continue
        if s.upper().startswith('WEBVTT'):
            continue
        # 去掉 VTT 的内联标签 <c>...</c>
        s = re.sub(r'<[^>]+>', '', s)
        if not s:
            continue
        if lines and lines[-1] == s:
            continue
        lines.append(s)
    text = ' '.join(lines)
    return re.sub(r'\s+', ' ', text).strip()[:TRANSCRIPT_MAX_CHARS]


def extract_audio(video: Path, wav: Path, limit_seconds: int):
    """抽 16k 单声道 wav（可选截断）。"""
    cmd = [str(FFMPEG), '-y', '-loglevel', 'error', '-i', str(video)]
    if limit_seconds > 0:
        cmd += ['-t', str(limit_seconds)]
    cmd += ['-vn', '-ac', '1', '-ar', str(SAMPLE_RATE), str(wav)]
    ok, _, stderr = run(cmd, timeout=300)
    return ok and wav.exists() and wav.stat().st_size > 0, stderr


def transcribe(wav: Path) -> str:
    """whisper.cpp 转写。
    注意：whisper-cli 对非 ASCII 绝对路径会崩（0xC0000409），
    所以 exe 用绝对路径，-m/-f 用相对名，cwd 设到 Release 目录。
    """
    if not WHISPER_EXE.exists() or not WHISPER_MODEL.exists():
        return ''
    # 把 wav 拷进 Release 目录，用相对名调用
    tmp_name = 'vwtmp.wav'
    tmp_here = WHISPER_DIR / tmp_name
    try:
        shutil.copyfile(wav, tmp_here)
    except Exception:
        return ''
    try:
        ok, stdout, stderr = run([
            str(WHISPER_EXE),
            '-m', WHISPER_MODEL.name,
            '-f', tmp_name,
            '-l', 'zh',
            '-nt',          # 不要时间轴
            '--no-prints',  # 不要杂讯
            '-t', '4',
            '--prompt', '以下是普通话的视频内容，请用简体中文转写。',
        ], cwd=str(WHISPER_DIR), timeout=600)
        text = (stdout or '').strip()
        if not text and stderr:
            # 有些版本把结果打到 stderr
            text = stderr.strip()
        return re.sub(r'\s+', ' ', text)[:TRANSCRIPT_MAX_CHARS]
    finally:
        try:
            tmp_here.unlink(missing_ok=True)
        except Exception:
            pass


def extract_frames(video: Path, outdir: Path, count: int, duration: int):
    """均匀抽 count 帧。"""
    outdir.mkdir(parents=True, exist_ok=True)
    frames = []
    if not video or not video.exists():
        return frames
    dur = duration if duration and duration > 0 else 60
    # 跳过开头 3%（常常是片头），从 5% 到 95% 均匀取
    start = max(0.0, dur * 0.05)
    end = max(start + 1.0, dur * 0.95)
    step = (end - start) / max(1, count)
    for i in range(count):
        t = start + step * i
        fp = outdir / f'f{i:02d}.jpg'
        cmd = [str(FFMPEG), '-y', '-loglevel', 'error',
               '-ss', f'{t:.2f}', '-i', str(video),
               '-frames:v', '1', '-vf', 'scale=640:-2',
               '-q:v', '4', str(fp)]
        ok, _, _ = run(cmd, timeout=60)
        if ok and fp.exists() and fp.stat().st_size > 0:
            frames.append(str(fp))
    return frames


def main():
    args = sys.argv[1:]
    if not args:
        fail('缺少视频链接', 'main')
    url = args[0]
    frame_count = 8
    max_mb = 80
    max_duration = 900
    for i, a in enumerate(args):
        if a == '--frames' and i + 1 < len(args):
            try:
                frame_count = max(1, min(16, int(args[i + 1])))
            except ValueError:
                pass
        if a == '--max-mb' and i + 1 < len(args):
            try:
                max_mb = max(5, min(500, int(args[i + 1])))
            except ValueError:
                pass
        if a == '--max-duration' and i + 1 < len(args):
            try:
                max_duration = max(30, min(3600, int(args[i + 1])))
            except ValueError:
                pass

    assert_safe_url(url)

    # 临时目录必须放在 workspace 内。
    # 血泪：DSH 的文件沙箱只允许子进程写 workspace 里的路径，
    # 用 tempfile.mkdtemp()（%TEMP%）时 ffmpeg 会报
    #   Could not open file ... / Error opening output ... Permission denied
    # 表现为抽帧 0 张、音频 0 字节，而 yt-dlp 下载却成功（它自己走 HTTP 流写盘）。
    tmp_root = TOOLS_DIR / '_video_tmp'
    tmp_root.mkdir(parents=True, exist_ok=True)
    # 收拾上一次的残留（帧文件和目录不会被 finally 清掉，怕长期堆积吃满磁盘）
    try:
        now = time.time()
        for old in tmp_root.iterdir():
            try:
                if old.is_dir() and (now - old.stat().st_mtime) > 1800:
                    shutil.rmtree(old, ignore_errors=True)
            except Exception:
                pass
    except Exception:
        pass
    workdir = Path(tempfile.mkdtemp(prefix='vw-', dir=str(tmp_root)))
    video = None
    result = {
        'ok': True,
        'title': '',
        'uploader': '',
        'duration': 0,
        'desc': '',
        'subtitleSource': 'none',
        'transcript': '',
        'frames': [],
        'frameCount': 0,
        'sizeMb': 0,
        'cleaned': True,
    }
    try:
        meta = fetch_info_and_media(url, workdir, max_mb, max_duration)
        video = meta['video']
        # yt-dlp 对直链 mp4 经常给不出 duration，用 ffmpeg 补一下，
        # 否则抽帧会按 60s 假定时长去 seek，短片直接一帧都取不到。
        if video and not meta['duration']:
            meta['duration'] = probe_duration(video)
        result.update({
            'title': meta['title'],
            'uploader': meta['uploader'],
            'duration': meta['duration'],
            'desc': meta['desc'],
            'sizeMb': meta['size_mb'],
        })

        # A 路线：先字幕
        transcript = ''
        if meta['sub_files']:
            for sf in meta['sub_files']:
                transcript = srt_to_text(sf)
                if len(transcript) > 40:
                    result['subtitleSource'] = 'subtitles'
                    break
                transcript = ''

        # A 路线兜底：转写音频
        if not transcript and video:
            wav = workdir / 'a.wav'
            ok, err = extract_audio(video, wav, TRANSCRIBE_MAX_SECONDS)
            if ok:
                transcript = transcribe(wav)
                if transcript:
                    result['subtitleSource'] = 'whisper'
                try:
                    wav.unlink(missing_ok=True)
                except Exception:
                    pass

        result['transcript'] = transcript

        # B 路线：抽帧
        frames_dir = workdir / 'frames'
        result['frames'] = extract_frames(video, frames_dir, frame_count, meta['duration'])
        result['frameCount'] = len(result['frames'])

        out(result)
    finally:
        # ── 「看完就删」：视频和临时文件全部清掉，只留 frames 给调用方读 ──
        # frames 会留到调用方读完再删（脚本删了调用方就读不到了）
        try:
            for p in workdir.iterdir():
                if p.is_dir():
                    continue
                p.unlink(missing_ok=True)
        except Exception:
            pass


if __name__ == '__main__':
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        fail(f'{type(e).__name__}: {e}', 'top')
