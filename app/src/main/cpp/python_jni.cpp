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

// Version marker — thay đổi mỗi lần rebuild APK
#define JNI_BUILD_VERSION __DATE__ " " __TIME__

// ============================================================
// Python C API typedefs
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
// Helper 1: copy file nếu cần (so sánh size)
// ============================================================
static bool copy_file_if_needed(const std::string& src, const std::string& dst) {
    struct stat st_src, st_dst;
    if (stat(src.c_str(), &st_src) != 0) return false;

    if (stat(dst.c_str(), &st_dst) == 0 &&
        st_src.st_size == st_dst.st_size) {
        return true;  // skip
    }

    unlink(dst.c_str());

    FILE* fin = fopen(src.c_str(), "rb");
    if (!fin) { LOGE("copy: mở src fail %s", src.c_str()); return false; }
    FILE* fout = fopen(dst.c_str(), "wb");
    if (!fout) { LOGE("copy: tạo dst fail %s", dst.c_str()); fclose(fin); return false; }

    char buf[65536];
    size_t n;
    bool ok = true;
    while ((n = fread(buf, 1, sizeof(buf), fin)) > 0) {
        if (fwrite(buf, 1, n, fout) != n) { ok = false; break; }
    }
    fclose(fin);
    fclose(fout);

    if (ok) chmod(dst.c_str(), 0755);
    else unlink(dst.c_str());
    return ok;
}

// ============================================================
// Helper 2: sync libpython + deps từ APK → pythonHome/lib
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
        if (stat(src.c_str(), &st_src) != 0) continue;

        struct stat st_dst;
        bool need_copy = true;
        if (stat(dst.c_str(), &st_dst) == 0 && st_src.st_size == st_dst.st_size) {
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
    LOGI("Sync libpython: %d synced, %d skipped, %d failed", synced, skipped, failed);
}

// ============================================================
// Helper 3: verify ELF có đủ 2 hash tables không
// Đọc trực tiếp file, không cần readelf
// ============================================================
static bool verify_elf_has_dt_hash(const std::string& path) {
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;

    unsigned char ehdr[64];
    size_t r = fread(ehdr, 1, 64, f);
    if (r < 64) { fclose(f); return false; }

    // Check ELF magic
    if (ehdr[0] != 0x7F || ehdr[1] != 'E' || ehdr[2] != 'L' || ehdr[3] != 'F') {
        fclose(f); return false;
    }

    // ELF64 little-endian
    if (ehdr[4] != 2 || ehdr[5] != 1) { fclose(f); return false; }

    // e_shoff ở offset 0x28 (8 bytes)
    uint64_t e_shoff = 0;
    memcpy(&e_shoff, ehdr + 0x28, 8);

    // e_shentsize ở 0x3A (2 bytes), e_shnum ở 0x3C
    uint16_t e_shentsize = 0, e_shnum = 0;
    memcpy(&e_shentsize, ehdr + 0x3A, 2);
    memcpy(&e_shnum, ehdr + 0x3C, 2);

    if (e_shoff == 0 || e_shnum == 0) { fclose(f); return false; }

    // Đọc section headers để tìm SHT_HASH (4) và SHT_GNU_HASH (0x6ffffff6)
    bool has_sysv = false, has_gnu = false;

    fseek(f, e_shoff, SEEK_SET);
    for (int i = 0; i < e_shnum; i++) {
        unsigned char shdr[64];
        if (fread(shdr, 1, 64, f) != 64) break;

        uint32_t sh_type = 0;
        memcpy(&sh_type, shdr + 4, 4);

        if (sh_type == 4)          has_sysv = true;   // SHT_HASH
        if (sh_type == 0x6ffffff6) has_gnu  = true;   // SHT_GNU_HASH
    }
    fclose(f);
    return has_sysv && has_gnu;
}

// ============================================================
// Helper 4: verify critical extensions trong lib-dynload
// ============================================================
static void verify_dynload_extensions(const char* pythonHome) {
    std::string dynloadDir = std::string(pythonHome) +
        "/lib/python3.13/lib-dynload";

    const char* critical[] = {
        "_posixsubprocess.cpython-313-aarch64-linux-android.so",
        "_ssl.cpython-313-aarch64-linux-android.so",
        "_sqlite3.cpython-313-aarch64-linux-android.so",
        "_socket.cpython-313-aarch64-linux-android.so",
        nullptr
    };

    int bad = 0;
    for (int i = 0; critical[i]; i++) {
        std::string path = dynloadDir + "/" + critical[i];
        struct stat st;
        if (stat(path.c_str(), &st) != 0) {
            LOGW("⚠️  Không có: %s", critical[i]);
            continue;
        }
        if (!verify_elf_has_dt_hash(path)) {
            LOGE("❌ %s — thiếu DT_HASH hoặc DT_GNU_HASH", critical[i]);
            bad++;
        }
    }

    if (bad > 0) {
        LOGE("");
        LOGE("╔══════════════════════════════════════════════════════════╗");
        LOGE("║  %d file trong lib-dynload thiếu hash table!             ║", bad);
        LOGE("║  → pip/subprocess sẽ fail khi import                     ║");
        LOGE("║  → User cần: Settings → Apps → Clear data                ║");
        LOGE("╚══════════════════════════════════════════════════════════╝");
        LOGE("");
    } else {
        LOGI("✅ Tất cả extension trong lib-dynload có đủ 2 hash tables");
    }
}

// ============================================================
// Helper 5: đọc/ghi version marker
// ============================================================
static std::string read_marker(const std::string& path) {
    FILE* f = fopen(path.c_str(), "r");
    if (!f) return "";
    char buf[256] = {0};
    if (!fgets(buf, sizeof(buf), f)) { fclose(f); return ""; }
    fclose(f);
    std::string s(buf);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
    return s;
}

static void write_marker(const std::string& path, const std::string& value) {
    FILE* f = fopen(path.c_str(), "w");
    if (!f) return;
    fputs(value.c_str(), f);
    fclose(f);
}

// ============================================================
// Helper 6: check version marker, log cảnh báo nếu mismatch
// ============================================================
static void check_runtime_version(const char* pythonHome) {
    std::string markerPath = std::string(pythonHome) + "/.runtime_version";
    std::string current = read_marker(markerPath);
    std::string expected = JNI_BUILD_VERSION;

    if (current == expected) {
        LOGI("✅ Runtime version OK (%s)", expected.c_str());
        return;
    }

    if (current.empty()) {
        LOGI("ℹ️  Lần đầu chạy — marker chưa có");
    } else {
        LOGW("⚠️  Runtime version mismatch!");
        LOGW("   Cũ:  %s", current.c_str());
        LOGW("   Mới: %s", expected.c_str());
        LOGW("   → Java code phải extract lại python-runtime.tar");
    }

    write_marker(markerPath, expected);
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

    LOGI("═══════════════════════════════════════════════════════════");
    LOGI("nativeLibDir: %s", nativeLibDir);
    LOGI("pythonHome:   %s", pythonHome);
    LOGI("filesDir:     %s", filesDir);
    LOGI("JNI version:  %s", JNI_BUILD_VERSION);
    LOGI("═══════════════════════════════════════════════════════════");

    // ========================================================
    // [v5] Check version marker — cảnh báo nếu mismatch
    // ========================================================
    check_runtime_version(pythonHome);

    // ========================================================
    // [v5] Verify extensions trong lib-dynload trước khi init
    // ========================================================
    verify_dynload_extensions(pythonHome);

    // ========================================================
    // Sync libpython + deps từ APK → pythonHome/lib
    // ========================================================
    LOGI("🔄 Sync native libs vào pythonHome/lib...");
    sync_native_libs_to_python_home(nativeLibDir, pythonHome);

    // ========================================================
    // Set env vars
    // ========================================================
    setenv("PYTHONHOME", pythonHome, 1);

    std::string stdlib   = std::string(pythonHome) + "/lib/python3.13";
    std::string dynload  = stdlib + "/lib-dynload";
    std::string sitePkgs = stdlib + "/site-packages";
    std::string pythonPath = stdlib + ":" + dynload + ":" + sitePkgs + ":" + filesDir;
    setenv("PYTHONPATH", pythonPath.c_str(), 1);
    LOGI("PYTHONPATH = %s", pythonPath.c_str());

    std::string pyLibDir = std::string(pythonHome) + "/lib";
    std::string ldPath = std::string(nativeLibDir) + ":" + stdlib + ":" + pyLibDir;
    setenv("LD_LIBRARY_PATH", ldPath.c_str(), 1);
    LOGI("LD_LIBRARY_PATH = %s", ldPath.c_str());

    std::string caBundle = sitePkgs + "/certifi/cacert.pem";
    setenv("SSL_CERT_FILE", caBundle.c_str(), 1);
    setenv("REQUESTS_CA_BUNDLE", caBundle.c_str(), 1);
    setenv("CURL_CA_BUNDLE", caBundle.c_str(), 1);

    std::string tmpDir = std::string(filesDir) + "/tmp";
    mkdir(tmpDir.c_str(), 0700);
    setenv("TMPDIR", tmpDir.c_str(), 1);
    setenv("TEMP", tmpDir.c_str(), 1);
    setenv("TMP", tmpDir.c_str(), 1);

    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("PYTHONUNBUFFERED", "1", 1);

    // ========================================================
    // dlopen từ pythonHome/lib (đã sync), fallback nativeLibDir
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
    LOGI("✅ dlopen libpython3.13 OK");

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

    // Verify PyLong_Type
    {
        void* pylong_ptr = dlsym(g_libpython, "PyLong_Type");
        if (pylong_ptr) {
            LOGI("✅ PyLong_Type resolved: %p", pylong_ptr);
        } else {
            LOGE("❌ PyLong_Type KHÔNG có trong libpython đã load!");
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
        LOGW("⚠️ Python đã init trước đó — skip");
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

    // Test imports
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

    rc = p_PyRun_SimpleString("import ssl; print('SSL_OK', ssl.OPENSSL_VERSION)");
    LOGI("Test import ssl: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _ssl không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    rc = p_PyRun_SimpleString("import sqlite3; print('SQLITE_OK')");
    LOGI("Test import sqlite3: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _sqlite3 không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    rc = p_PyRun_SimpleString("import _posixsubprocess; print('POSIX_SUBPROCESS_OK')");
    LOGI("Test import _posixsubprocess: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ _posixsubprocess không load được — pip sẽ fail");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    rc = p_PyRun_SimpleString("import subprocess; print('SUBPROCESS_OK')");
    LOGI("Test import subprocess: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ subprocess không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    rc = p_PyRun_SimpleString("import yt_dlp; print('YTDLP_OK', yt_dlp.version.__version__)");
    LOGI("Test import yt_dlp: rc=%d", rc);
    if (rc != 0) {
        LOGW("⚠️ yt_dlp không load được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    std::string code = "import sys\n";
    code += "if r'" + std::string(filesDir) + "' not in sys.path:\n";
    code += "    sys.path.insert(0, r'" + std::string(filesDir) + "')\n";
    p_PyRun_SimpleString(code.c_str());

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
                            out = "{\"success\":false,\"error\":\"Cannot serialize\"}";
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
    // Không dlclose — tránh crash cleanup
}

} // extern "C"