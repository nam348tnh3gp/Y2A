import yt_dlp
import os

class DownloadProgress:
    """Lớp lưu trữ tiến trình tải để Kotlin có thể truy vấn."""
    def __init__(self):
        self.status = "idle"
        self.percent = 0.0
        self.speed = ""
        self.eta = -1
        self.filename = ""
        self.error = None

# Biến toàn cục lưu trạng thái gần nhất
current_progress = DownloadProgress()

def progress_hook(d):
    """Callback được yt-dlp gọi trong quá trình tải."""
    global current_progress
    
    status = d.get('status')
    
    if status == 'downloading':
        current_progress.status = "downloading"
        total = d.get('total_bytes') or d.get('total_bytes_estimate') or 0
        downloaded = d.get('downloaded_bytes', 0)
        
        if total > 0:
            current_progress.percent = (downloaded / total) * 100
        else:
            current_progress.percent = 0.0
            
        current_progress.speed = d.get('_speed_str', '').strip()
        eta = d.get('eta')
        current_progress.eta = int(eta) if eta is not None else -1
        current_progress.filename = d.get('filename', '')
        
    elif status == 'finished':
        current_progress.status = "finished"
        current_progress.percent = 100.0
        current_progress.filename = d.get('filename', '')

def get_progress():
    """Trả về dict tiến trình để Kotlin đọc."""
    global current_progress
    return {
        'status': current_progress.status,
        'percent': current_progress.percent,
        'speed': current_progress.speed,
        'eta': current_progress.eta,
        'filename': current_progress.filename,
        'error': current_progress.error
    }

def download(url, options):
    """
    Hàm chính để tải video/audio.
    
    Tham số:
        url (str): URL video
        options (dict): Tùy chọn từ Kotlin (format, audio_only, quality, v.v.)
    
    Trả về:
        dict: Kết quả với 'success' (bool) và 'error' (str nếu có)
    """
    global current_progress
    current_progress = DownloadProgress()
    
    try:
        # Xây dựng ydl_opts từ options
        ydl_opts = {
            'progress_hooks': [progress_hook],
            'quiet': True,
            'no_warnings': True,
            'noprogress': True,
        }
        
        # Đường dẫn ffmpeg từ FFmpegKit
        ffmpeg_path = options.get('ffmpeg_path')
        if ffmpeg_path:
            ydl_opts['ffmpeg_location'] = ffmpeg_path
        
        # Cookies
        cookies_file = options.get('cookies_file')
        if cookies_file and os.path.exists(cookies_file):
            ydl_opts['cookiefile'] = cookies_file
        
        # Format selector
        format_selector = options.get('format', 'best')
        ydl_opts['format'] = format_selector
        
        # Thư mục đầu ra
        output_dir = options.get('output_dir', '.')
        ydl_opts['outtmpl'] = os.path.join(output_dir, options.get('output_template', '%(title)s.%(ext)s'))
        
        # Playlist
        if options.get('playlist', False):
            ydl_opts['yes_playlist'] = True
            ydl_opts['ignoreerrors'] = True
        else:
            ydl_opts['noplaylist'] = True
        
        # Audio extraction
        if options.get('audio_only', False):
            audio_format = options.get('audio_format', 'mp3')
            audio_quality = options.get('audio_bitrate', '128')
            ydl_opts['postprocessors'] = [{
                'key': 'FFmpegExtractAudio',
                'preferredcodec': audio_format,
                'preferredquality': audio_quality,
            }]
        
        # Retry và delay
        ydl_opts['retries'] = 10
        ydl_opts['fragment_retries'] = 20
        ydl_opts['socket_timeout'] = 30
        
        # Extractor args cho YouTube
        if 'youtube.com' in url or 'youtu.be' in url:
            ydl_opts['extractor_args'] = {
                'youtube': {
                    'player_client': ['web', 'mweb', 'android', 'tv']
                }
            }
        
        # Thực hiện tải
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            ydl.download([url])
        
        return {'success': True, 'error': None}
        
    except Exception as e:
        current_progress.error = str(e)
        current_progress.status = "error"
        return {'success': False, 'error': str(e)}