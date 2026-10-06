#include <jni.h>
#include <string>
#include <android/log.h>
#include <dlfcn.h>
#include <cstring>
#include <cstdlib>

#define LOG_TAG "PythonJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================
// Function pointer typedefs (thay vì Python.h)
// ============================================================
typedef void* PyObject;
typedef void* PyObject_ptr;

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
typedef int      (*PyRun_SimpleFile_t)(void*, const char*);

static void* g_libpython = nullptr;
static bool  g_initialized = false;

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

extern "C" {

JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeInit(
        JNIEnv *env, jobject, jstring nativeLibDir, jstring sitePackagesDir) {

    if (g_initialized) return JNI_TRUE;

    const char *libDir = env->GetStringUTFChars(nativeLibDir, nullptr);
    const char *siteDir = env->GetStringUTFChars(sitePackagesDir, nullptr);

    LOGI("nativeLibDir: %s", libDir);
    LOGI("sitePackages: %s", siteDir);

    // Set env vars cho Python
    setenv("PYTHONHOME", libDir, 1);
    setenv("PYTHONPATH", siteDir, 1);
    setenv("PYTHONDONTWRITEBYTECODE", "1", 1);

    // Load libpython3.14.so
    std::string libPath = std::string(libDir) + "/libpython3.14.so";
    g_libpython = dlopen(libPath.c_str(), RTLD_NOW | RTLD_GLOBAL);
    if (!g_libpython) {
        LOGE("dlopen fail: %s", dlerror());
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        return JNI_FALSE;
    }
    LOGI("✅ dlopen libpython OK");

    // Load symbols
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

    #undef LOAD

    if (!p_Py_Initialize || !p_PyRun_SimpleString) {
        LOGE("Thiếu symbol bắt buộc");
        env->ReleaseStringUTFChars(nativeLibDir, libDir);
        env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
        return JNI_FALSE;
    }

    // Init Python
    p_Py_Initialize();

    if (p_Py_GetVersion) {
        LOGI("✅ Python: %s", p_Py_GetVersion());
    }

    // Thêm site-packages vào sys.path
    std::string code = "import sys\n";
    code += "sys.path.insert(0, r'" + std::string(siteDir) + "')\n";
    code += "sys.path.insert(0, r'" + std::string(libDir) + "')\n";
    p_PyRun_SimpleString(code.c_str());

    g_initialized = true;

    env->ReleaseStringUTFChars(nativeLibDir, libDir);
    env->ReleaseStringUTFChars(sitePackagesDir, siteDir);
    return JNI_TRUE;
}

JNIEXPORT jstring JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeCallFunction(
        JNIEnv *env, jobject, jstring moduleName, jstring funcName, jstring argJson) {

    if (!g_initialized || !p_PyImport_ImportModule) {
        return env->NewStringUTF("{\"success\":false,\"error\":\"Python chưa init\"}");
    }

    const char *mod = env->GetStringUTFChars(moduleName, nullptr);
    const char *fn = env->GetStringUTFChars(funcName, nullptr);
    const char *arg = env->GetStringUTFChars(argJson, nullptr);

    PyObject pModule = p_PyImport_ImportModule(mod);
    if (!pModule) {
        if (p_PyErr_Print) p_PyErr_Print();
        std::string err = "{\"success\":false,\"error\":\"Import failed: ";
        err += mod; err += "\"}";
        env->ReleaseStringUTFChars(moduleName, mod);
        env->ReleaseStringUTFChars(funcName, fn);
        env->ReleaseStringUTFChars(argJson, arg);
        return env->NewStringUTF(err.c_str());
    }

    PyObject pFunc = p_PyObject_GetAttrString(pModule, fn);
    if (!pFunc || (p_PyCallable_Check && !p_PyCallable_Check(pFunc))) {
        if (p_PyErr_Print) p_PyErr_Print();
        std::string err = "{\"success\":false,\"error\":\"Func not found: ";
        err += fn; err += "\"}";
        env->ReleaseStringUTFChars(moduleName, mod);
        env->ReleaseStringUTFChars(funcName, fn);
        env->ReleaseStringUTFChars(argJson, arg);
        return env->NewStringUTF(err.c_str());
    }

    PyObject pyArg = p_PyUnicode_FromString(arg);
    PyObject pArgs = p_PyTuple_Pack(1, pyArg);
    PyObject pResult = p_PyObject_CallObject(pFunc, pArgs);

    env->ReleaseStringUTFChars(moduleName, mod);
    env->ReleaseStringUTFChars(funcName, fn);
    env->ReleaseStringUTFChars(argJson, arg);

    if (!pResult) {
        if (p_PyErr_Print) p_PyErr_Print();
        return env->NewStringUTF("{\"success\":false,\"error\":\"Call failed\"}");
    }

    PyObject pStr = p_PyObject_Str(pResult);
    const char *result = p_PyUnicode_AsUTF8 ? p_PyUnicode_AsUTF8(pStr) : "";

    jstring ret = env->NewStringUTF(result ? result : "");
    return ret;
}

JNIEXPORT void JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeFinalize(
        JNIEnv *env, jobject) {
    if (g_initialized && p_Py_Finalize) {
        p_Py_Finalize();
        g_initialized = false;
    }
    if (g_libpython) {
        dlclose(g_libpython);
        g_libpython = nullptr;
    }
}

} // extern "C"