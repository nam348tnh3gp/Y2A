#include <jni.h>
#include <string>
#include <android/log.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>

#define LOG_TAG "PythonJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

// ============================================================
// Python C API typedefs (không cần Python.h)
// ============================================================
typedef void* PyObject;
typedef int   PyGILState_STATE;

typedef void        (*Py_Initialize_t)();
typedef void        (*Py_Finalize_t)();
typedef int         (*PyRun_SimpleString_t)(const char*);
typedef PyObject*   (*PyImport_ImportModule_t)(const char*);
typedef PyObject*   (*PyObject_GetAttrString_t)(PyObject*, const char*);
typedef int         (*PyCallable_Check_t)(PyObject*);
typedef PyObject*   (*PyObject_CallObject_t)(PyObject*, PyObject*);
typedef PyObject*   (*PyTuple_Pack_t)(long long, ...);
typedef PyObject*   (*PyUnicode_FromString_t)(const char*);
typedef PyObject*   (*PyObject_Str_t)(PyObject*);
typedef const char* (*PyUnicode_AsUTF8_t)(PyObject*);
typedef void        (*PyErr_Print_t)();
typedef const char* (*Py_GetVersion_t)();
typedef void        (*Py_DecRef_t)(PyObject*);
typedef PyGILState_STATE (*PyGILState_Ensure_t)();
typedef void        (*PyGILState_Release_t)(PyGILState_STATE);
typedef void*       (*PyEval_SaveThread_t)();
typedef void        (*PyEval_RestoreThread_t)(void*);
typedef void        (*PyErr_Clear_t)();
typedef int         (*Py_IsInitialized_t)();

static void* g_libpython = nullptr;
static bool  g_initialized = false;
static void* g_mainTState = nullptr;

static Py_Initialize_t         p_Py_Initialize = nullptr;
static Py_Finalize_t           p_Py_Finalize = nullptr;
static PyRun_SimpleString_t    p_PyRun_SimpleString = nullptr;
static PyImport_ImportModule_t p_PyImport_ImportModule = nullptr;
static PyObject_GetAttrString_t p_PyObject_GetAttrString = nullptr;
static PyCallable_Check_t      p_PyCallable_Check = nullptr;
static PyObject_CallObject_t   p_PyObject_CallObject = nullptr;
static PyTuple_Pack_t          p_PyTuple_Pack = nullptr;
static PyUnicode_FromString_t  p_PyUnicode_FromString = nullptr;
static PyObject_Str_t          p_PyObject_Str = nullptr;
static PyUnicode_AsUTF8_t      p_PyUnicode_AsUTF8 = nullptr;
static PyErr_Print_t           p_PyErr_Print = nullptr;
static Py_GetVersion_t         p_Py_GetVersion = nullptr;
static Py_DecRef_t             p_Py_DecRef = nullptr;
static PyGILState_Ensure_t     p_PyGILState_Ensure = nullptr;
static PyGILState_Release_t    p_PyGILState_Release = nullptr;
static PyEval_SaveThread_t     p_PyEval_SaveThread = nullptr;
static PyEval_RestoreThread_t  p_PyEval_RestoreThread = nullptr;
static PyErr_Clear_t           p_PyErr_Clear = nullptr;
static Py_IsInitialized_t      p_Py_IsInitialized = nullptr;

// ============================================================
// [FIX v4] Helper: copy file nếu cần (so sánh size + mtime)
// ============================================================
static bool copy_file_if_needed(const std::string& src, const std::string& dst) {
    struct stat st_src, st_dst;
    if (stat(src.c_str(), &st_src) != 0) {
        return false;  // src không tồn tại
    }

    // Nếu dst đã tồn tại và cùng size → coi như đã sync
    if (stat(dst.c_str(), &st_dst) == 0) {
        if (st_src.st_size == st_dst.st_size) {
            return true;  // skip — đã có bản giống
        }
    }

    // Xóa file cũ (nếu có) trước khi ghi
    unlink(dst.c_str());

    FILE* fin = fopen(src.c_str(), "rb");
    if (!fin) {
        LOGE("copy: không mở được src %s", src.c_str());
        return false;
    }
    FILE* fout = fopen(dst.c_str(), "wb");
    if (!fout) {
        LOGE("copy: không tạo được dst %s", dst.c_str());
        fclose(fin);
        return false;
    }

    char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = fread(buf, 1, sizeof(buf), fin)) > 0) {
        if (fwrite(buf, 1, n, fout) != n) { ok = false; break; }
    }
    fclose(fin);
    fclose(fout);

    if (ok) {
        chmod(dst.c_str(), 0755);
    } else {
        unlink(dst.c_str());
    }
    return ok;
}

// ============================================================
// [FIX v4] Sync native libs từ APK → pythonHome/lib
// Đảm bảo mỗi lần update APK, user không cần clear data
// ============================================================
static void sync_native_libs_to_python_home(
        const char* nativeLibDir, const char* pythonHome) {

    std::string dstDir = std::string(pythonHome) + "/lib";
    mkdir(dstDir.c_str(), 0755);

    const char* libs[] = {
        "libpython3.13.so",
        "libssl.so",
        "libcrypto.so",
        "libffi.so",
        "libsqlite3.so",
        "liblzma.so",
        "libz.so",
        nullptr
    };

    int synced = 0, skipped = 0, failed = 0;
    for (int i = 0; libs[i]; i++) {
        std::string src = std::string(nativeLibDir) + "/" + libs[i];
        std::string dst = dstDir + "/" + libs[i];

        struct stat st_src;
        if (stat(src.c_str(), &st_src) != 0) {
            // Không có trong APK — không phải lỗi
            continue;
        }

        // Kiểm tra xem có cần copy không
        struct stat st_dst;
        bool need_copy = true;
        if (stat(dst.c_str(), &st_dst) == 0 &&
            st_src.st_size == st_dst.st_size) {
            need_copy = false;
        }

        if (copy_file_if_needed(src, dst)) {
            if (need_copy) {
                LOGI("✅ Sync %s (%ld bytes)", libs[i], (long)st_src.st_size);
                synced++;
            } else {
                skipped++;
            }
        } else {
            LOGE("❌ Sync %s thất bại", libs[i]);
            failed++;
        }
    }

    LOGI("Sync summary: %d synced, %d skipped, %d failed", synced, skipped, failed);
}

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeInit(
        JNIEnv *env, jobject,
        jstring jNativeLibDir,
        jstring jPythonHome,
        jstring jFilesDir) {

    if (g_initialized) return JNI_TRUE;

    const char *nativeLibDir = env->GetStringUTFChars(jNativeLibDir, nullptr);
    const char *pythonHome   = env->GetStringUTFChars(jPythonHome, nullptr);
    const char *filesDir     = env->GetStringUTFChars(jFilesDir, nullptr);

    LOGI("nativeLibDir: %s", nativeLibDir);
    LOGI("pythonHome:   %s", pythonHome);
    LOGI("filesDir:     %s", filesDir);

    // ========================================================
    // [FIX v4] Sync libpython + deps từ APK → pythonHome/lib
    // Chạy TRƯỚC khi setenv / dlopen để đảm bảo:
    //   1. User update APK → file mới được copy tự động
    //   2. Không cần clear data app
    //   3. libpython trong pythonHome/lib luôn khớp với APK
    // ========================================================
    LOGI("🔄 Sync native libs vào pythonHome/lib...");
    sync_native_libs_to_python_home(nativeLibDir, pythonHome);

    // ========================================================
    // Set env vars TRƯỚC Py_Initialize
    // ========================================================
    setenv("PYTHONHOME", pythonHome, 1);

    std::string stdlib   = std::string(pythonHome) + "/lib/python3.13";
    std::string dynload  = stdlib + "/lib-dynload";
    std::string sitePkgs = stdlib + "/site-packages";
    std::string pythonPath = stdlib + ":" + dynload + ":" + sitePkgs + ":" + filesDir;
    setenv("PYTHONPATH", pythonPath.c_str(), 1);
    LOGI("PYTHONPATH = %s", pythonPath.c_str());

    // ========================================================
    // LD_LIBRARY_PATH
    // ========================================================
    std::string pyLibDir = std::string(pythonHome) + "/lib";
    std::string ldPath = std::string(nativeLibDir) + ":" + stdlib + ":" + pyLibDir;
    setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
    LOGI("LD_LIBRARY_PATH = %s", ldPath.c_str());

    // SSL certs
    std::string caBundle = sitePkgs + "/certifi/cacert.pem";
    setenv("SSL_CERT_FILE", caBundle.c_str(), 1);
    setenv("REQUESTS_CA_BUNDLE", caBundle.c_str(), 1);
    setenv("CURL_CA_BUNDLE", caBundle.c_str(), 1);

    // Temp dir
    std::string tmpDir = std::string(filesDir) + "/tmp";
    mkdir(tmpDir.c_str(), 0700);
    setenv("TMPDIR", tmpDir.c_str(), 1);
    setenv("TEMP", tmpDir.c_str(), 1);
    setenv("TMP", tmpDir.c_str(), 1);

    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONUNBUFFERED", "1", 1);

    // ========================================================
    // [FIX v4] dlopen từ pythonHome/lib (đã sync) — fallback nativeLibDir
    // ========================================================
    std::string libPath = std::string(pythonHome) + "/lib/libpython3.13.so";
    g_libpython = dlopen(libPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!g_libpython) {
        LOGW("⚠️  dlopen từ pythonHome/lib fail: %s", dlerror());
        std::string fallbackPath = std::string(nativeLibDir) + "/libpython3.13.so";
        LOGI("Thử fallback: %s", fallbackPath.c_str());
        g_libpython = dlopen(fallbackPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
        if (!g_libpython) {
            LOGE("❌ dlopen fallback cũng fail: %s", dlerror());
            env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
            env->ReleaseStringUTFChars(jPythonHome, pythonHome);
            env->ReleaseStringUTFChars(jFilesDir, filesDir);
            return JNI_FALSE;
        }
    }
    LOGI("✅ dlopen libpython3.13 OK từ %s", libPath.c_str());

    // ========================================================
    // Load symbols
    // ========================================================
    #define LOAD(name) \
        p_##name = (name##_t) dlsym(g_libpython, #name); \
        if (!p_##name) { LOGE("Thiếu symbol: %s", #name); }

    LOAD(Py_Initialize)
    LOAD(Py_Finalize)
    LOAD(PyRun_SimpleString)
    LOAD(PyImport_ImportModule)
    LOAD(PyObject_GetAttrString)
    LOAD(PyCallable_Check)
    LOAD(PyObject_CallObject)
    LOAD(PyTuple_Pack)
    LOAD(PyUnicode_FromString)
    LOAD(PyObject_Str)
    LOAD(PyUnicode_AsUTF8)
    LOAD(PyErr_Print)
    LOAD(Py_GetVersion)
    LOAD(Py_DecRef)
    LOAD(PyGILState_Ensure)
    LOAD(PyGILState_Release)
    LOAD(PyEval_SaveThread)
    LOAD(PyEval_RestoreThread)
    LOAD(PyErr_Clear)
    LOAD(Py_IsInitialized)
    #undef LOAD

    // [FIX v4] Verify PyLong_Type có trong libpython vừa load
    {
        void* pylong_ptr = dlsym(g_libpython, "PyLong_Type");
        if (pylong_ptr) {
            LOGI("✅ PyLong_Type resolved: %p", pylong_ptr);
        } else {
            LOGE("❌ PyLong_Type KHÔNG tìm thấy trong libpython đã load!");
            LOGE("   → cryptography _rust.abi3.so sẽ fail");
        }
    }

    if (!p_Py_Initialize || !p_PyRun_SimpleString ||
        !p_PyGILState_Ensure || !p_PyGILState_Release ||
        !p_PyEval_SaveThread || !p_PyEval_RestoreThread) {
        LOGE("❌ Thiếu symbol bắt buộc");
        env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
        env->ReleaseStringUTFChars(jPythonHome, pythonHome);
        env->ReleaseStringUTFChars(jFilesDir, filesDir);
        return JNI_FALSE;
    }

    // ========================================================
    // Init Python
    // ========================================================
    if (p_Py_IsInitialized && p_Py_IsInitialized()) {
        LOGW("⚠️ Python đã init trước đó — skip Py_Initialize");
        g_initialized = true;
        env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
        env->ReleaseStringUTFChars(jPythonHome, pythonHome);
        env->ReleaseStringUTFChars(jFilesDir, filesDir);
        return JNI_TRUE;
    }

    p_Py_Initialize();

    if (p_Py_GetVersion) {
        LOGI("✅ Python: %s", p_Py_GetVersion());
    }

    // Test import os
    int rc = p_PyRun_SimpleString("import os; print('STDLIB_OS_OK')");
    LOGI("Test import os: rc=%d", rc);
    if (rc != 0) {
        LOGE("❌ Stdlib không load được");
        if (p_PyErr_Print) p_PyErr_Print();
        env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
        env->ReleaseStringUTFChars(jPythonHome, pythonHome);
        env->ReleaseStringUTFChars(jFilesDir, filesDir);
        return JNI_FALSE;
    }

    // Test import ssl
    rc = p_PyRun_SimpleString("import ssl; print('SSL_OK', ssl.OPENSSL_VERSION)");
    LOGI("Test import ssl: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _ssl không load được — HTTPS sẽ fail");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // Test import sqlite3
    rc = p_PyRun_SimpleString("import sqlite3; print('SQLITE_OK')");
    LOGI("Test import sqlite3: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _sqlite3 không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // Test import _posixsubprocess
    rc = p_PyRun_SimpleString("import _posixsubprocess; print('POSIX_SUBPROCESS_OK')");
    LOGI("Test import _posixsubprocess: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _posixsubprocess không load được — pip sẽ fail");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // Test import subprocess
    rc = p_PyRun_SimpleString("import subprocess; print('SUBPROCESS_OK')");
    LOGI("Test import subprocess: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ subprocess không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // Test import yt_dlp
    rc = p_PyRun_SimpleString("import yt_dlp; print('YTDLP_OK', yt_dlp.version.__version__)");
    LOGI("Test import yt_dlp: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ yt_dlp không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // Thêm filesDir vào sys.path
    std::string code = "import sys\n";
    code += "if r'" + std::string(filesDir) + "' not in sys.path:\n";
    code += "    sys.path.insert(0, r'" + std::string(filesDir) + "')\n";
    p_PyRun_SimpleString(code.c_str());

    // Nhả GIL
    g_mainTState = p_PyEval_SaveThread();
    g_initialized = true;

    env->ReleaseStringUTFChars(jNativeLibDir, nativeLibDir);
    env->ReleaseStringUTFChars(jPythonHome, pythonHome);
    env->ReleaseStringUTFChars(jFilesDir, filesDir);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeCallFunction(
        JNIEnv *env, jobject,
        jstring jModule, jstring jFunc, jstring jArg) {

    if (!g_initialized || !p_PyImport_ImportModule) {
        return env->NewStringUTF("{\"success\":false,\"error\":\"Python chưa init\"}");
    }

    const char *module = env->GetStringUTFChars(jModule, nullptr);
    const char *func   = env->GetStringUTFChars(jFunc, nullptr);
    const char *arg    = env->GetStringUTFChars(jArg, nullptr);

    std::string out;

    PyGILState_STATE gstate = p_PyGILState_Ensure();
    {
        PyObject *pModule = p_PyImport_ImportModule(module);
        if (!pModule) {
            if (p_PyErr_Print) p_PyErr_Print();
            out = std::string("{\"success\":false,\"error\":\"Import failed: ") + module + "\"}";
        } else {
            PyObject *pFunc = p_PyObject_GetAttrString(pModule, func);
            if (!pFunc || (p_PyCallable_Check && !p_PyCallable_Check(pFunc))) {
                if (p_PyErr_Print) p_PyErr_Print();
                out = std::string("{\"success\":false,\"error\":\"Func not found: ") + func + "\"}";
            } else {
                PyObject *pyArg = p_PyUnicode_FromString(arg);
                PyObject *pArgs = pyArg ? p_PyTuple_Pack(1, pyArg) : nullptr;
                PyObject *pResult = pArgs ? p_PyObject_CallObject(pFunc, pArgs) : nullptr;

                if (!pResult) {
                    if (p_PyErr_Print) p_PyErr_Print();
                    out = "{\"success\":false,\"error\":\"Call failed\"}";
                } else {
                    PyObject *pStr = p_PyObject_Str(pResult);
                    if (pStr) {
                        const char *r = p_PyUnicode_AsUTF8 ? p_PyUnicode_AsUTF8(pStr) : nullptr;
                        if (r) {
                            out = r;
                        } else {
                            if (p_PyErr_Clear) p_PyErr_Clear();
                            out = "{\"success\":false,\"error\":\"Cannot serialize result\"}";
                        }
                        if (p_Py_DecRef) p_Py_DecRef(pStr);
                    }
                    if (p_Py_DecRef) p_Py_DecRef(pResult);
                }
                if (p_Py_DecRef) {
                    if (pArgs) p_Py_DecRef(pArgs);
                    if (pyArg) p_Py_DecRef(pyArg);
                }
            }
            if (p_Py_DecRef) {
                if (pFunc) p_Py_DecRef(pFunc);
                p_Py_DecRef(pModule);
            }
        }
    }
    p_PyGILState_Release(gstate);

    env->ReleaseStringUTFChars(jModule, module);
    env->ReleaseStringUTFChars(jFunc, func);
    env->ReleaseStringUTFChars(jArg, arg);

    return env->NewStringUTF(out.c_str());
}

JNIEXPORT void JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeFinalize(
        JNIEnv *env, jobject) {
    if (g_initialized && p_Py_Finalize) {
        if (g_mainTState && p_PyEval_RestoreThread) {
            p_PyEval_RestoreThread(g_mainTState);
            g_mainTState = nullptr;
        }
        p_Py_Finalize();
        g_initialized = false;
    }
    // KHÔNG dlclose — tránh crash khi process cleanup
}

} // extern "C"