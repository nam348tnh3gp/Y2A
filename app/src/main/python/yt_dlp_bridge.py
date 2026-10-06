import yt_dlp
import os
import json
import urllib.request

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

def get_info(url, cookies_file=""):
    # Không cần convert vì get_info nhận tham số riêng lẻ
    ydl_opts = {
        'quiet': True,
        'no_warnings': True,
        'noplaylist': True,
        'skip_download': True,
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
            return {
                'title': info.get('title', ''),
                'uploader': info.get('uploader', ''),
                'duration': info.get('duration', 0) or 0,
                'thumbnail': info.get('thumbnail'),
            }
    except Exception:
        return {'title': '', 'uploader': '', 'duration': 0, 'thumbnail': None}

def download(url, options):
    # ⚠️ QUAN TRỌNG: convert Java Map (LinkedHashMap) thành Python dict
    # để có thể dùng .get(key, default) đúng chuẩn Python
    options = dict(options)

    global current_progress
    current_progress = DownloadProgress()
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
            ydl_opts['postprocessors'] = [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': options.get('audio_format', 'mp3'),
                'preferredquality': options.get('audio_bitrate', '128'),
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

        return {'success': True, 'error': None}
    except Exception as e:
        current_progress.error = str(e)
        current_progress.status = "error"
        return {'success': False, 'error': str(e)}
