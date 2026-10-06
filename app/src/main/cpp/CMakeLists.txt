cmake_minimum_required(VERSION 3.22.1)
project("ffmpeg_jni")

add_library(ffmpeg_jni SHARED ffmpeg_jni.cpp)

find_library(log-lib log)
target_link_libraries(ffmpeg_jni ${log-lib})