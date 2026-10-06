#include <jni.h>
#include <string>
#include <android/log.h>
#include <Python.h>
#include <cstring>
#include <cstdlib>
#include <unistd.h>
#include <sys/stat.h>

#define LOG_TAG "PythonJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static bool g_python_initialized = false;

extern "C" {

/**
 * Khởi tạo Python interpreter với PYTHONHOME chỉ định.
 * @param pythonHome đường dẫn tới thư mục chứa stdlib (filesDir/python3.14)
 */
JNIEXPORT jboolean JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeInit(
        JNIEnv *env, jobject /* this */, jstring pythonHome) {

    if (g_python_initialized) {
        LOGI("Python đã được khởi tạo trước đó");
        return JNI_TRUE;
    }

    const char *home = env->GetStringUTFChars(pythonHome, nullptr);
    if (home == nullptr) return JNI_FALSE;

    LOGI("Khởi tạo Python với PYTHONHOME=%s", home);

    // Cấu hình Python 3.14
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.use_environment = 0;      // Không đọc env vars
    config.isolated = 0;             // Cho phép site-packages
    config.site_import = 1;          // Import site module

    // Set PYTHONHOME
    PyStatus status = PyConfig_SetBytesString(&config, &config.home, home);
    if (PyStatus_Exception(status)) {
        LOGE("PyConfig_SetBytesString(home) failed: %s", status.err_msg);
        PyConfig_Clear(&config);
        env->ReleaseStringUTFChars(pythonHome, home);
        return JNI_FALSE;
    }

    // Program name (bắt buộc)
    PyConfig_SetBytesString(&config, &config.program_name, "python3.14");

    // Khởi tạo Python
    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    env->ReleaseStringUTFChars(pythonHome, home);

    if (PyStatus_Exception(status)) {
        LOGE("Py_InitializeFromConfig failed: %s", status.err_msg);
        return JNI_FALSE;
    }

    g_python_initialized = true;
    LOGI("✅ Python khởi tạo thành công. Version: %s", Py_GetVersion());

    // Cấu hình sys.path để tìm site-packages
    PyRun_SimpleString(
        "import sys, os\n"
        "sys.path.insert(0, os.path.join(sys.prefix, 'lib', 'python3.14'))\n"
        "sys.path.insert(0, os.path.join(sys.prefix, 'lib', 'python3.14', 'site-packages'))\n"
        "sys.path.insert(0, os.path.join(sys.prefix, 'lib', 'python3.14', 'lib-dynload'))\n"
    );

    return JNI_TRUE;
}

/**
 * Chạy một biểu thức Python và trả về kết quả dạng string.
 * Input có thể là string code hoặc file path (nếu là *.py).
 */
JNIEXPORT jstring JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeRun(
        JNIEnv *env, jobject /* this */, jstring codeOrPath) {

    if (!g_python_initialized) {
        return env->NewStringUTF("ERROR: Python chưa được khởi tạo");
    }

    const char *input = env->GetStringUTFChars(codeOrPath, nullptr);
    std::string inputStr(input);
    env->ReleaseStringUTFChars(codeOrPath, input);

    // Nếu input kết thúc bằng .py → chạy như file script
    if (inputStr.size() > 3 && inputStr.substr(inputStr.size() - 3) == ".py") {
        FILE *fp = fopen(inputStr.c_str(), "r");
        if (!fp) {
            std::string err = "ERROR: Không mở được file: " + inputStr;
            return env->NewStringUTF(err.c_str());
        }

        // Chạy file Python
        int result = PyRun_SimpleFile(fp, inputStr.c_str());
        fclose(fp);

        if (result != 0) {
            return env->NewStringUTF("ERROR: Python script failed");
        }
        return env->NewStringUTF("OK");
    }

    // Chạy như string code
    PyObject *main_module = PyImport_AddModule("__main__");
    PyObject *global_dict = PyModule_GetDict(main_module);
    PyObject *local_dict = PyDict_New();

    PyObject *result = PyRun_String(inputStr.c_str(), Py_file_input, global_dict, local_dict);
    Py_DECREF(local_dict);

    if (result == nullptr) {
        PyErr_Print();
        return env->NewStringUTF("ERROR: Python execution failed");
    }
    Py_DECREF(result);
    return env->NewStringUTF("OK");
}

/**
 * Gọi một hàm Python trong module cụ thể với JSON argument.
 * Trả về JSON string từ hàm Python.
 */
JNIEXPORT jstring JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeCallFunction(
        JNIEnv *env, jobject /* this */,
        jstring moduleName, jstring funcName, jstring argJson) {

    if (!g_python_initialized) {
        return env->NewStringUTF("{\"success\":false,\"error\":\"Python chưa khởi tạo\"}");
    }

    const char *modName = env->GetStringUTFChars(moduleName, nullptr);
    const char *fnName = env->GetStringUTFChars(funcName, nullptr);
    const char *arg = env->GetStringUTFChars(argJson, nullptr);

    // Import module
    PyObject *pModule = PyImport_ImportModule(modName);
    if (pModule == nullptr) {
        PyErr_Print();
        std::string err = "{\"success\":false,\"error\":\"Không import được module ";
        err += modName; err += "\"}";
        env->ReleaseStringUTFChars(moduleName, modName);
        env->ReleaseStringUTFChars(funcName, fnName);
        env->ReleaseStringUTFChars(argJson, arg);
        return env->NewStringUTF(err.c_str());
    }

    // Lấy hàm
    PyObject *pFunc = PyObject_GetAttrString(pModule, fnName);
    if (pFunc == nullptr || !PyCallable_Check(pFunc)) {
        PyErr_Print();
        std::string err = "{\"success\":false,\"error\":\"Không tìm thấy hàm ";
        err += fnName; err += "\"}";
        Py_XDECREF(pFunc);
        Py_DECREF(pModule);
        env->ReleaseStringUTFChars(moduleName, modName);
        env->ReleaseStringUTFChars(funcName, fnName);
        env->ReleaseStringUTFChars(argJson, arg);
        return env->NewStringUTF(err.c_str());
    }

    // Tạo argument
    PyObject *pArgs = PyTuple_Pack(1, PyUnicode_FromString(arg));
    PyObject *pResult = PyObject_CallObject(pFunc, pArgs);

    Py_DECREF(pArgs);
    Py_DECREF(pFunc);
    Py_DECREF(pModule);
    env->ReleaseStringUTFChars(moduleName, modName);
    env->ReleaseStringUTFChars(funcName, fnName);
    env->ReleaseStringUTFChars(argJson, arg);

    if (pResult == nullptr) {
        PyErr_Print();
        return env->NewStringUTF("{\"success\":false,\"error\":\"Hàm Python thất bại\"}");
    }

    // Convert kết quả thành string
    PyObject *pStr = PyObject_Str(pResult);
    const char *resultCStr = PyUnicode_AsUTF8(pStr);
    jstring result = env->NewStringUTF(resultCStr ? resultCStr : "");

    Py_DECREF(pStr);
    Py_DECREF(pResult);
    return result;
}

/**
 * Finalize Python khi app đóng.
 */
JNIEXPORT void JNICALL
Java_com_nam2006_y2mate_PythonBridge_nativeFinalize(
        JNIEnv *env, jobject /* this */) {
    if (g_python_initialized) {
        Py_Finalize();
        g_python_initialized = false;
        LOGI("Python đã finalize");
    }
}

} // extern "C"