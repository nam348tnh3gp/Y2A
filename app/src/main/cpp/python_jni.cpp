#include <jni.h>
#include <string>
#include <android/log.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_TAG "PythonJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================
// Function pointer typedefs
// ============================================================
typedef void* PyObject;
typedef void     (*Py_Initialize_t)();
typedef void     (*Py_Finalize_t)();
typedef int      (*PyRun_SimpleString_t)(const char*);
typedef PyObject (*PyImport_ImportModule_t)(const char*);
typedef PyObject (*PyObject_GetAttrString_t)(PyObject, const char*);
typedef int      (*PyCallable_Check_t)(PyObject);
typedef PyObject (*PyObject_CallObject_t)(PyObject, PyObject);
typedef PyObject (*PyTuple_Pack_t)(long, ...);
typedef PyObject (*PyUnicode_FromString_t)(const char*);
typedef PyObject (*PyObject_Str_t)(PyObject);
typedef const char* (*PyUnicode_AsUTF8_t)(PyObject);
typedef void     (*PyErr_Print_t)();
typedef const char* (*Py_GetVersion_t)();
typedef void     (*Py_DecRef_t)(PyObject);
typedef int      (*PyGILState_Ensure_t)();
typedef void     (*PyGILState_Release_t)(int);
typedef void*    (*PyEval_SaveThread_t)();
typedef void     (*PyEval_RestoreThread_t)(void*);
typedef void     (*PyErr_Clear_t)();

static void* g_libpython = nullptr;
static bool  g_initialized = false;
static void* g_mainTState = nullptr;

static Py_Initialize_t           p_Py_Initialize = nullptr;
static Py_Finalize_t             p_Py_Finalize = nullptr;
static PyRun_SimpleString_t      p_PyRun_SimpleString = nullptr;
static PyImport_ImportModule_t   p_PyImport_ImportModule = nullptr;
static PyObject_GetAttrString_t  p_PyObject_GetAttrString = nullptr;
static PyCallable_Check_t        p_PyCallable_Check = nullptr;
static PyObject_CallObject_t     p_PyObject_CallObject = nullptr;
static PyTuple_Pack_t            p_PyTuple_Pack = nullptr;
static PyUnicode_FromString_t    p_PyUnicode_FromString = nullptr;
static PyObject_Str_t            p_PyObject_Str = nullptr;
static PyUnicode_AsUTF8_t        p_PyUnicode_AsUTF8 = nullptr;
static PyErr_Print_t             p_PyErr_Print = nullptr;
static Py_GetVersion_t           p_Py_GetVersion = nullptr;
static Py_DecRef_t               p_Py_DecRef = nullptr;
static PyGILState_Ensure_t       p_PyGILState_Ensure = nullptr;
static PyGILState_Release_t      p_PyGILState_Release = nullptr;
static PyEval_SaveThread_t       p_PyEval_SaveThread = nullptr;
static PyEval_RestoreThread_t    p_PyEval_RestoreThread = nullptr;
static PyErr_Clear_t             p_PyErr_Clear = nullptr;

// ============================================================
// Helper: Trích xuất file ZIP từ assets ra filesystem
// ============================================================
static bool extractZipFromAssets(
        JNIEnv *env, jobject assetManager,
        const char* assetName, const char* destPath) {

    // Mở asset
    jclass assetManagerClass = env->GetObjectClass(assetManager);
    jmethodID openMethod = env->GetMethodID(assetManagerClass, "open",
        "(Ljava/lang/String;)Ljava/io/InputStream;");
    jstring jAssetName = env->NewStringUTF(assetName);
    jobject inputStream = env->CallObjectMethod(assetManager, openMethod, jAssetName);
    env->DeleteLocalRef(jAssetName);

    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return false;
    }

    // Tạo file đích
    FILE* destFile = fopen(destPath, "wb");
    if (!destFile) return false;

    // Đọc từng byte từ InputStream
    jclass inputStreamClass = env->GetObjectClass(inputStream);
    jmethodID readMethod = env->GetMethodID(inputStreamClass, "read", "()I");

    while (true) {
        jint byte = env->CallIntMethod(inputStream, readMethod);
        if (env->ExceptionCheck() || byte == -1) break;
        fputc((char)byte, destFile);
    }

    fclose(destFile);
    env->DeleteLocalRef(inputStream);
    return true;
}

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeInit(
        JNIEnv *env, jobject,
        jstring nativeLibDir, jstring sitePackagesDir, jstring filesDir,
        jobject assetManager) {

    if (g_initialized) return JNI_TRUE;

    const char *libDir = env->GetStringUTFChars(nativeLibDir, nullptr);
    const char *siteDir = env->GetStringUTFChars(sitePackagesDir, nullptr);
    const char *filesDirC = env->GetStringUTFChars(filesDir, nullptr);

    LOGI("nativeLibDir: %s", libDir);
    LOGI("sitePackages: %s", siteDir);
    LOGI("filesDir:    %s", filesDirC);

    // ========================================================
    // 1. Trích xuất stdlib.zip từ assets
    // ========================================================
    std::string stdlibZipDest = std::string(filesDirC) + "/stdlib.zip";
    bool stdlibOk = extractZipFromAssets(
        env, assetManager, "python/stdlib.zip", stdlibZipDest.c_str());

    if (!stdlibOk) {
        // Fallback: thử lấy từ libpythonbundle.so
        LOGI("stdlib.zip không có trong assets, thử từ libpythonbundle.so...");
        std::string bundlePath = std::string(libDir) + "/libpythonbundle.so";
        // TODO: extract stdlib.zip from bundle
    }

    if (!stdlibOk) {
        LOGE("❌ Không trích xuất được stdlib.zip");
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        env->ReleaseStringUTFChars(filesDir, filesDirC);
        return JNI_FALSE;
    }

    // ========================================================
    // 2. Trích xuất sitepackages.zip từ assets
    // ========================================================
    std::string sitePackagesZipDest = std::string(filesDirC) + "/sitepackages.zip";
    bool siteOk = extractZipFromAssets(
        env, assetManager, "python/sitepackages.zip", sitePackagesZipDest.c_str());

    if (!siteOk) {
        LOGW("⚠️ sitepackages.zip không có trong assets (có thể dùng site-packages folder)");
    }

    // ========================================================
    // 3. Load libpython3.14.so
    // ========================================================
    std::string libPath = std::string(libDir) + "/libpython3.14.so";
    g_libpython = dlopen(libPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!g_libpython) {
        LOGE("❌ dlopen fail: %s", dlerror());
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        env->ReleaseStringUTFChars(filesDir, filesDirC);
        return JNI_FALSE;
    }
    LOGI("✅ dlopen libpython OK");

    // ========================================================
    // 4. Load symbols
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
    #undef LOAD

    if (!p_Py_Initialize || !p_PyRun_SimpleString ||
        !p_PyGILState_Ensure || !p_PyGILState_Release ||
        !p_PyEval_SaveThread || !p_PyEval_RestoreThread) {
        LOGE("❌ Thiếu symbol bắt buộc");
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        env->ReleaseStringUTFChars(filesDir, filesDirC);
        return JNI_FALSE;
    }

    // ========================================================
    // 5. Set env vars cho Python
    // ========================================================
    // PYTHONHOME: trỏ đến thư mục chứa stdlib.zip
    // Python sẽ tự động thêm stdlib.zip vào sys.path khi tìm thấy nó trong $PYTHONHOME/lib
    setenv("PYTHONHOME", filesDirC, 1);
    setenv("PYTHONPATH", siteDir, 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);
    setenv("LD_LIBRARY_PATH", libDir, 1);

    // ========================================================
    // 6. Init Python
    // ========================================================
    p_Py_Initialize();

    if (p_Py_GetVersion) {
        LOGI("✅ Python: %s", p_Py_GetVersion());
    }

    // ========================================================
    // 7. TEST: import os
    // ========================================================
    int rc_test = p_PyRun_SimpleString("import os; print('STDLIB_OS_OK')");
    LOGI("Test import os: rc=%d", rc_test);

    if (rc_test != 0) {
        LOGE("❌ Stdlib không load được");
        if (p_PyErr_Print) p_PyErr_Print();
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        env->ReleaseStringUTFChars(filesDir, filesDirC);
        return JNI_FALSE;
    }

    // ========================================================
    // 8. Thêm sys.path: filesDir, site-packages, zip files
    // ========================================================
    std::string code = "import sys\n";
    code += "sys.path.insert(0, r'" + std::string(filesDirC) + "')\n";
    code += "sys.path.insert(0, r'" + std::string(filesDirC) + "/stdlib.zip')\n";
    if (siteOk) {
        code += "sys.path.insert(0, r'" + std::string(filesDirC) + "/sitepackages.zip')\n";
    } else {
        code += "sys.path.insert(0, r'" + std::string(siteDir) + "')\n";
    }
    code += "sys.path.insert(0, r'" + std::string(libDir) + "')\n";
    code += "print('sys.path:', sys.path[:6])\n";

    p_PyRun_SimpleString(code.c_str());

    // ========================================================
    // 9. TEST: import yt_dlp
    // ========================================================
    int rc_ytdlp = p_PyRun_SimpleString("import yt_dlp; print('YTDLP_OK', yt_dlp.version.__version__)");
    LOGI("Test import yt_dlp: rc=%d", rc_ytdlp);

    if (rc_ytdlp != 0) {
        LOGE("⚠️ yt_dlp không import được");
        if (p_PyErr_Print) p_PyErr_Print();
    }

    // ========================================================
    // 10. Nhả GIL
    // ========================================================
    g_mainTState = p_PyEval_SaveThread();
    g_initialized = true;

    env->ReleaseStringUTFChars(nativeLibDir, libDir);
    env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
    env->ReleaseStringUTFChars(filesDir, filesDirC);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeCallFunction(
        JNIEnv *env, jobject, jstring moduleName, jstring funcName, jstring argJson) {

    if (!g_initialized || !p_PyImport_ImportModule) {
        return env->NewStringUTF("{\"success\":false,\"error\":\"Python chua init\"}");
    }

    const char *mod = env->GetStringUTFChars(moduleName, nullptr);
    const char *fn = env->GetStringUTFChars(funcName, nullptr);
    const char *arg = env->GetStringUTFChars(argJson, nullptr);

    std::string out;

    int gstate = p_PyGILState_Ensure();
    {
        PyObject pModule = p_PyImport_ImportModule(mod);
        if (!pModule) {
            if (p_PyErr_Print) p_PyErr_Print();
            out = std::string("{\"success\":false,\"error\":\"Import failed: ") + mod + "\"}";
        } else {
            PyObject pFunc = p_PyObject_GetAttrString(pModule, fn);
            if (!pFunc || (p_PyCallable_Check && !p_PyCallable_Check(pFunc))) {
                if (p_PyErr_Print) p_PyErr_Print();
                out = std::string("{\"success\":false,\"error\":\"Func not found: ") + fn + "\"}";
            } else {
                PyObject pyArg = p_PyUnicode_FromString(arg);
                PyObject pArgs = pyArg ? p_PyTuple_Pack(1, pyArg) : nullptr;
                PyObject pResult = pArgs ? p_PyObject_CallObject(pFunc, pArgs) : nullptr;

                if (!pResult) {
                    if (p_PyErr_Print) p_PyErr_Print();
                    out = "{\"success\":false,\"error\":\"Call failed\"}";
                } else {
                    PyObject pStr = p_PyObject_Str(pResult);
                    if (pStr) {
                        const char *r = p_PyUnicode_AsUTF8 ? p_PyUnicode_AsUTF8(pStr) : nullptr;
                        if (r) out = r;
                        else if (p_PyErr_Clear) p_PyErr_Clear();
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

    env->ReleaseStringUTFChars(moduleName, mod);
    env->ReleaseStringUTFChars(functionName, fn);
    env->ReleaseStringUTFChars(argJson, arg);

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
    if (g_libpython) {
        dlclose(g_libpython);
        g_libpython = nullptr;
    }
}

} // extern "C"