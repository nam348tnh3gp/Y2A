cmake_minimum_required(VERSION 3.22.1)
project("y2mate_jni")

# ---------- FFmpeg JNI ----------
add_library(ffmpeg_jni SHARED ffmpeg_jni.cpp)
find_library(log-lib log)
target_link_libraries(ffmpeg_jni ${log-lib})

# ---------- Python JNI ----------
add_library(python_jni SHARED python_jni.cpp)

# Đường dẫn tới Python runtime trong assets
set(PYTHON_RUNTIME_DIR "${CMAKE_SOURCE_DIR}/../assets/python")

# Include headers của Python runtime
target_include_directories(python_jni PRIVATE
    "${PYTHON_RUNTIME_DIR}/include"
    "${PYTHON_RUNTIME_DIR}/include/python3.14"
)

# Link libpython3.14.so từ jniLibs
set(PYTHON_LIB_DIR "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
add_library(python3.14 SHARED IMPORTED)
set_target_properties(python3.14 PROPERTIES
    IMPORTED_LOCATION "${PYTHON_LIB_DIR}/libpython3.14.so"
)

target_link_libraries(python_jni
    python3.14
    ${log-lib}
    android
)