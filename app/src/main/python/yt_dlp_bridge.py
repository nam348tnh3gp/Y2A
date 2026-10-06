import yt_dlp
import os
import json
import threading
import urllib.request

# ============================================================
# Cancel flag — chia sẻ giữa các lần gọi từ Kotlin
# ============================================================
_cancel_event = threading.Event()

# Lấy exception class để raise khi user hủy.
# yt-dlp hiện đại có DownloadCancelled, fallback nếu không có.
try:
    from yt_dlp.utils import DownloadCancelled as _CancelExc
except ImportError:
    class _CancelExc(Exception):
        pass


class DownloadProgress:
    def __init__(self):
        self.status = "idle"
        self.percent = 0.0
        self.speed = ""
        self.eta = -1
        self.filename = ""
        self.error = None


current_progress = DownloadProgress()


# ============================================================
# Progress hook — kiểm tra cancel mỗi lần gọi
# ============================================================
def progress_hook(d):
    global current_progress

    # User bấm hủy → raise để yt-dlp dừng ngay
    if _cancel_event.is_set():
        raise _CancelExc("cancelled by user")

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
# API cho Kotlin — progress & cancel
# ============================================================

def get_progress(_args_json="{}"):
    """
    Kotlin gọi định kỳ (mỗi 1s) để lấy tiến độ.
    Trả JSON: status, percent, speed, eta, filename
    """
    p = current_progress
    return json.dumps({
        'status': p.status,
        'percent': p.percent,
        'speed': p.speed,
        'eta': p.eta,
        'filename': p.filename,
    })


def cancel_download(_args_json="{}"):
    """
    Đặt cờ hủy. progress_hook sẽ raise ở lần gọi kế tiếp,
    khiến yt-dlp dừng tải ngay lập tức.
    """
    _cancel_event.set()
    return json.dumps({'success': True})


# ============================================================
# API cho Kotlin — kiểm tra phiên bản yt-dlp
# ============================================================

def get_installed_version():
    return yt_dlp.version.__version__


def get_latest_version():
    try:
        url = "https://pypi.org/pypi/yt-dlp/json"
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.loads(response.read().decode())
            return data["info"]["version"]
    except Exception as e:
        return f"Error: {e}"


# ============================================================
# API cho Kotlin — lấy thông tin preview
# ============================================================

def get_info(url, cookies_file=""):
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'noplaylist': True,
        'skip_download': True,
        'socket_timeout': 20,
        'retries': 2,
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


# ============================================================
# API cho Kotlin — tải chính
# ============================================================

def download(url, options_json):
    """
    Nhận options dưới dạng JSON string từ Kotlin.
    Trả JSON: {'success': bool, 'error': str | null, 'cancelled': bool (optional)}
    """
    try:
        options = json.loads(options_json)
    except Exception as e:
        return json.dumps({'success': False, 'error': f'Invalid options JSON: {e}'})

    global current_progress
    current_progress = DownloadProgress()
    _cancel_event.clear()

    try:
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

        cookies_file = options.get('cookies_file')
        if cookies_file and os.path.exists(cookies_file):
            ydl_opts['cookiefile'] = cookies_file

        if options.get('playlist', False):
            ydl_opts['yes_playlist'] = True
            ydl_opts['ignoreerrors'] = True
        else:
            ydl_opts['noplaylist'] = True

        if options.get('audio_only', False):
            # ================= AUDIO MODE =================
            ydl_opts['postprocessors'] = [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': options.get('audio_format', 'mp3'),
                'preferredquality': options.get('audio_bitrate', '128'),
            }]
        else:
            # ================= VIDEO MODE =================
            vf = options.get('video_format', 'mp4').lower()
            iphone = options.get('iphone', False)

            if iphone:
                # iPhone compatible: luôn mp4 (H.264 + AAC)
                ydl_opts['merge_output_format'] = 'mp4'
            elif vf in ('mp4', 'mkv', 'webm'):
                # Định dạng yt-dlp merge trực tiếp được
                ydl_opts['merge_output_format'] = vf
            else:
                # avi, mov, flv → merge mp4 trước rồi recode bằng FFmpeg
                ydl_opts['merge_output_format'] = 'mp4'
                ydl_opts['postprocessors'] = [{
                    'key': 'FFmpegVideoConvertor',
                    'preferedformat': vf,   # Lưu ý: API viết thiếu 'r', giữ nguyên
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

        # Trường hợp yt-dlp nuốt exception và không raise khi bị hủy
        if _cancel_event.is_set():
            current_progress.status = "cancelled"
            return json.dumps({
                'success': False,
                'error': 'cancelled',
                'cancelled': True,
            })

        return json.dumps({'success': True, 'error': None})
    except Exception as e:
        # Phân biệt hủy với lỗi thật
        if _cancel_event.is_set():
            current_progress.status = "cancelled"
            return json.dumps({
                'success': False,
                'error': 'cancelled',
                'cancelled': True,
            })
        current_progress.error = str(e)
        current_progress.status = "error"
        return json.dumps({'success': False, 'error': str(e)})