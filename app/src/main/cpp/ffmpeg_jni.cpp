#include <jni.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>
#include <android/log.h>
#include <cstdlib>
#include <cstring>
#include <vector>

#define LOG_TAG "FFmpegJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

extern "C" {

// Cấp quyền thực thi cho file binary (chmod 755)
JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_Downloader_nativeChmod(JNIEnv *env, jobject /* this */, jstring path) {
    const char *cPath = env->GetStringUTFChars(path, nullptr);
    if (cPath == nullptr) return JNI_FALSE;

    int result = chmod(cPath, 0755);
    env->ReleaseStringUTFChars(path, cPath);

    if (result == 0) {
        LOGI("chmod 755 successful: %s", cPath);
        return JNI_TRUE;
    } else {
        LOGE("chmod 755 failed: %s, errno: %d", cPath, errno);
        return JNI_FALSE;
    }
}

// Thực thi FFmpeg qua linker để vượt hạn chế Android 11+
JNIEXPORT jint JNICALL
Java_com_nam2006_y2mate_Downloader_nativeExecFfmpeg(JNIEnv *env, jobject /* this */,
                                                     jstring binaryPath, jobjectArray args) {
    const char *cBinary = env->GetStringUTFChars(binaryPath, nullptr);
    if (cBinary == nullptr) return -1;

    jsize argCount = env->GetArrayLength(args);
    std::vector<const char*> argv;
    
    // Dùng linker64 để gọi binary (vượt noexec)
    argv.push_back("/system/bin/linker64");
    argv.push_back(cBinary);

    for (jsize i = 0; i < argCount; i++) {
        jstring jArg = (jstring) env->GetObjectArrayElement(args, i);
        const char *cArg = env->GetStringUTFChars(jArg, nullptr);
        argv.push_back(cArg);
    }
    argv.push_back(nullptr);

    pid_t pid = fork();
    if (pid == 0) {
        // Child process
        execv(argv[0], const_cast<char* const*>(argv.data()));
        LOGE("execv failed: %s", strerror(errno));
        _exit(127);
    } else if (pid > 0) {
        // Parent process
        int status;
        waitpid(pid, &status, 0);
        
        // Cleanup
        for (size_t i = 2; i < argv.size() - 1; i++) {
            env->ReleaseStringUTFChars(
                (jstring) env->GetObjectArrayElement(args, i - 2), argv[i]);
        }
        env->ReleaseStringUTFChars(binaryPath, cBinary);
        
        return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    env->ReleaseStringUTFChars(binaryPath, cBinary);
    return -1;
}

// Kiểm tra binary có tồn tại và thực thi được không
JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_Downloader_nativeCanExecute(JNIEnv *env, jobject /* this */, jstring path) {
    const char *cPath = env->GetStringUTFChars(path, nullptr);
    if (cPath == nullptr) return JNI_FALSE;

    jboolean result = (access(cPath, X_OK) == 0) ? JNI_TRUE : JNI_FALSE;
    env->ReleaseStringUTFChars(path, cPath);
    return result;
}

} // extern "C"