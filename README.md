# Mini-Y2mate Pro — bản Android native

App Android (Kotlin + Jetpack Compose) chạy **yt-dlp + FFmpeg ngay trên điện thoại** nhờ thư viện
[youtubedl-android](https://github.com/yausername/youtubedl-android) (bản 0.18.1). Không cần server, không cần Termux.

## Tính năng (chuyển từ bản web `app.py`)
- 3 tab YouTube / Facebook / TikTok, tự nhận nền tảng khi dán link
- Xem trước (ảnh bìa, tiêu đề, kênh, thời lượng)
- Video (mp4/webm/mkv/avi/mov/flv, 360p–4K) hoặc Audio (mp3/m4a/aac/flac/ogg/wav/opus + bitrate)
- iPhone Compatible (H.264 + AAC), tải playlist (mỗi playlist một thư mục)
- Tiến độ + tốc độ + thời gian còn lại, **thông báo + chạy nền** (có nút Hủy), "Thử lại" tải tiếp phần dang dở
- Lịch sử, mở / chia sẻ file, nhập `cookies.txt`
- Nhận link từ nút **Chia sẻ** của app YouTube / Facebook / TikTok
- File lưu ở `Download/Mini-Y2mate` (không cần cấp quyền lưu trữ)

## Build APK trên GitHub (không cần Android Studio — làm được ngay trên Termux)
```bash
pkg install git gh
gh auth login
cd Y2mateAndroid
git init && git add . && git commit -m "init"
gh repo create y2mate-android --private --source=. --push   # push xong workflow tự chạy
gh run watch                                                # theo dõi build (~8-15 phút lần đầu)
gh run download -n Mini-Y2mate-Pro-apk                      # tải file .apk về
```
Hoặc vào tab **Actions → Build APK → Run workflow** trên github.com rồi tải artifact `Mini-Y2mate-Pro-apk`.
Mở file `.apk` để cài (cho phép "Cài ứng dụng không rõ nguồn gốc").

## Build bằng Android Studio
Mở thư mục này → để Studio sync Gradle → Run. (JDK 17, Android SDK 35.)

## Lưu ý
- Yêu cầu **Android 10 trở lên** (minSdk 29). APK nặng (~100 MB) vì chứa Python + yt-dlp + FFmpeg cho arm64 và arm32.
  Muốn nhẹ hơn: trong `app/build.gradle.kts` đổi `abiFilters` chỉ còn `"arm64-v8a"`.
- **yt-dlp hay lỗi khi YouTube đổi cách chặn.** Cách chắc chắn nhất: tăng `youtubedlAndroid` trong
  `app/build.gradle.kts` lên bản mới nhất rồi build lại. Nút "Cập nhật yt-dlp" trong app chỉ là thử nghiệm.
- YouTube thường đòi đăng nhập ("Sign in to confirm you're not a bot"): bấm 🍪 trong app và nhập `cookies.txt`.
  Bản Android **không** tự lấy cookies từ trình duyệt như bản web.
- APK ký bằng khóa debug → chỉ để cài trực tiếp, **không đưa lên Google Play** (chính sách Play cấm app tải video YouTube).
- Thư viện youtubedl-android theo giấy phép GPL-3.0; nếu bạn phát hành lại app thì cần tuân thủ giấy phép đó.
# Y2A
