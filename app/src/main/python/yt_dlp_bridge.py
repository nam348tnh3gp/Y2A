import yt_dlp
import os
import json
import threading
import urllib.request

try:
    from yt_dlp.utils import DownloadCancelled as _CancelBase
except Exception:  # bản yt-dlp cũ
    _CancelBase = Exception


class UserCancelled(_CancelBase):
    """Người dùng bấm Hủy. Kế thừa DownloadCancelled để yt-dlp không nuốt lỗi khi ignoreerrors (playlist)."""
    def __init__(self, msg="cancelled"):
        super().__init__(msg)


_cancel = threading.Event()


class DownloadProgress:
    def __init__(self):
        self.status = "idle"
        self.percent = 0.0
        self.speed = ""
        self.eta = -1
        self.filename = ""
        self.error = None

current_progress = DownloadProgress()

def progress_hook(d):
    global current_progress
    if _cancel.is_set():
        raise UserCancelled()
    status = d.get('status')
    if status == 'downloading':
        current_progress.status = "downloading"
        total = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
        downloaded = d.get('downloaded_bytes', 0)
        current_progress.percent = (downloaded / total * 100) if total > 0 else 0.0
        current_progress.speed = d.get('_speed_str', '').strip()
        eta = d.get('eta')
        current_progress.eta = int(eta) if eta is not None else -1
        current_progress.filename = d.get('filename', '')
    elif status == 'finished':
        current_progress.status = "finished"
        current_progress.percent = 100.0
        current_progress.filename = d.get('filename', '')


# ============================================================
# JSON API cho JNI (Kotlin gọi qua PythonBridge.callFunction)
# ============================================================

def get_info_json(args_json):
    """args: {"url": "...", "cookies_file": "..."}"""
    try:
        args = json.loads(args_json)
        url = args.get("url", "")
        cookies_file = args.get("cookies_file", "")
    except Exception as e:
        return json.dumps({'title': '', 'uploader': '', 'duration': 0, 'thumbnail': ''})

    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'noplaylist': True,
        'skip_download': True,
        'socket_timeout': 20,      # tránh treo vô hạn khi mạng chập chờn
        'retries': 2,
        'extractor_retries': 1,
    }
    if cookies_file and os.path.exists(cookies_file):
        ydl_opts['cookiefile'] = cookies_file
    if 'youtube.com' in url or 'youtu.be' in url:
        ydl_opts['extractor_args'] = {
            'youtube': {'player_client': ['web', 'mweb', 'android', 'tv']}
        }
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=False)
            return json.dumps({
                'title': info.get('title', ''),
                'uploader': info.get('uploader', ''),
                'duration': info.get('duration', 0) or 0,
                'thumbnail': info.get('thumbnail') or '',
            })
    except Exception:
        return json.dumps({'title': '', 'uploader': '', 'duration': 0, 'thumbnail': ''})


def get_progress_json(_args_json="{}"):
    """Kotlin gọi định kỳ để lấy tiến độ."""
    p = current_progress
    return json.dumps({
        'status': p.status,
        'percent': p.percent,
        'speed': p.speed,
        'eta': p.eta,
        'filename': p.filename,
    })


def cancel_json(_args_json="{}"):
    """Đặt cờ hủy; progress_hook sẽ raise ở lần gọi kế tiếp."""
    _cancel.set()
    return json.dumps({'success': True})


def check_versions_json(args_json):
    """args: {} → {"installed": "...", "latest": "..."}"""
    try:
        installed = yt_dlp.version.__version__
    except Exception:
        installed = "unknown"

    try:
        url = "https://pypi.org/pypi/yt-dlp/json"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode())
            latest = data["info"]["version"]
    except Exception as e:
        latest = f"Error: {e}"

    return json.dumps({'installed': installed, 'latest': latest})


def download_json(options_json):
    """args: toàn bộ options từ Kotlin → {"success": bool, "error": str}"""
    try:
        options = json.loads(options_json)
    except Exception as e:
        return json.dumps({'success': False, 'error': f'Invalid JSON: {e}'})

    global current_progress
    current_progress = DownloadProgress()
    _cancel.clear()

    try:
        url = options.get('url', '')
        ydl_opts = {
            'progress_hooks': [progress_hook],
            'quiet': True,
            'no_warnings': True,
            'noprogress': True,
            'format': options.get('format', 'best'),
            'outtmpl': os.path.join(
                options.get('output_dir', '.'),
                options.get('output_template', '%(title)s.%(ext)s')
            ),
        }

        ffmpeg_path = options.get('ffmpeg_path')
        if ffmpeg_path:
            ydl_opts['ffmpeg_location'] = ffmpeg_path
            os.environ['LD_LIBRARY_PATH'] = os.path.dirname(ffmpeg_path)

        cookies_file = options.get('cookies_file')
        if cookies_file and os.path.exists(cookies_file):
            ydl_opts['cookiefile'] = cookies_file

        if options.get('playlist', False):
            ydl_opts['yes_playlist'] = True
            ydl_opts['ignoreerrors'] = True
        else:
            ydl_opts['noplaylist'] = True

        if options.get('audio_only', False):
            ydl_opts['postprocessors'] = [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': options.get('audio_format', 'mp3'),
                'preferredquality': options.get('audio_bitrate', '128'),
            }]
        else:
            vf = options.get('video_format', 'mp4').lower()
            iphone = options.get('iphone', False)
            if iphone:
                ydl_opts['merge_output_format'] = 'mp4'
            elif vf in ('mp4', 'mkv', 'webm'):
                ydl_opts['merge_output_format'] = vf
            else:
                ydl_opts['merge_output_format'] = 'mp4'
                ydl_opts['postprocessors'] = [{
                    'key': 'FFmpegVideoConvertor',
                    'preferedformat': vf,
                }]

        ydl_opts['retries'] = 10
        ydl_opts['fragment_retries'] = 20
        ydl_opts['socket_timeout'] = 30

        if 'youtube.com' in url or 'youtu.be' in url:
            ydl_opts['extractor_args'] = {
                'youtube': {'player_client': ['web', 'mweb', 'android', 'tv']}
            }

        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])

        return json.dumps({'success': True, 'error': None})
    except Exception as e:
        current_progress.error = str(e)
        current_progress.status = "error"
        return json.dumps({'success': False, 'error': str(e)})