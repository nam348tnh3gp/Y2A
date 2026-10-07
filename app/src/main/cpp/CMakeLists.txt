cmake_minimum_required(VERSION 3.22.1)
project("y2mate_jni")

# ============================================================
# Tương thích linker Android 12:
# - --hash-style=both : tạo cả SYSV hash (DT_HASH) và GNU hash (DT_GNU_HASH)
#   để linker cũ đọc được. Bắt buộc với Android 12 trở xuống.
# ============================================================
add_link_options("-Wl,--hash-style=both")

# ---------- FFmpeg JNI ----------
add_library(ffmpeg_jni SHARED ffmpeg_jni.cpp)
find_library(log-lib log)
target_link_libraries(ffmpeg_jni ${log-lib})

# ---------- Python JNI ----------
add_library(python_jni SHARED python_jni.cpp)

target_link_libraries(python_jni
    ${log-lib}
    android
    dl
)