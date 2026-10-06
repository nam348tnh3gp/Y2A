cmake_minimum_required(VERSION 3.22.1)
project("y2mate_jni")

# ---------- FFmpeg JNI ----------
add_library(ffmpeg_jni SHARED ffmpeg_jni.cpp)
find_library(log-lib log)
target_link_libraries(ffmpeg_jni ${log-lib})

# ---------- Python JNI ----------
# Dùng dlopen, KHÔNG cần Python.h
add_library(python_jni SHARED python_jni.cpp)

target_link_libraries(python_jni
    ${log-lib}
    android
    dl
)