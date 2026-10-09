#!/bin/bash
# Entrypoint chạy trong Docker container
set -eo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🐳 p4a-style wheel builder"
echo "════════════════════════════════════════════════════════════"

source "${CARGO_HOME}/env" 2>/dev/null || true

WORKSPACE="$(pwd)"
export WORKSPACE
export TARGET_ROOT="${WORKSPACE}/python-android"
export TARGET_STDLIB="${TARGET_ROOT}/lib/python${PYTHON_MINOR}"
export TARGET_SITE="${TARGET_STDLIB}/site-packages"
export DEPS_INSTALL="${WORKSPACE}/deps-install"
export WHEELS_OUT="${WORKSPACE}/wheels-out"
export WHEELS_FINAL="${WORKSPACE}/wheels-final"
export NDK_SYSROOT="${NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot"
export NDK_PREBUILT="${NDK}/toolchains/llvm/prebuilt/linux-x86_64"
export CLANG_BUILTIN=$(${CC} -print-resource-dir 2>/dev/null)/include
export HOST_PY_PREFIX="${HOST_PY_PREFIX:-/opt/host-python}"
export HOST_PY_LIB="${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"

mkdir -p "${TARGET_ROOT}" "${DEPS_INSTALL}" "${WHEELS_OUT}" "${WHEELS_FINAL}"

# 1. Cross-compile core deps
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo ""
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh || { echo "❌ cross-compile-deps.sh FAILED"; exit 1; }
    touch "${DEPS_INSTALL}/.done"
else
    echo "⏭️  deps-install có sẵn — skip"
fi

# 2. Cross-compile CPython
if [ ! -f "${TARGET_ROOT}/.python-built" ]; then
    echo ""
    echo "🔨 Cross-compile CPython..."
    bash scripts/cross-compile-python.sh || { echo "❌ cross-compile-python.sh FAILED"; exit 1; }
    touch "${TARGET_ROOT}/.python-built"
else
    echo "⏭️  python-android có sẵn — skip"
fi

# ════════════════════════════════════════════════════════════
# 3. Setup sysconfigdata + sitecustomize
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Setup sysconfig cho host python"

TARGET_SYSCONF=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
[ -z "$TARGET_SYSCONF" ] && { echo "❌ Không có _sysconfigdata"; exit 1; }

SYSCONF_NAME=$(basename "$TARGET_SYSCONF" .py)
echo "  Source:  $TARGET_SYSCONF"
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"

export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
echo "  _PYTHON_SYSCONFIGDATA_NAME=$SYSCONF_NAME"

for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

# Patch sysconfigdata files
echo "  Patch sysconfigdata files"
for f in "${HOST_PY_LIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    sed -i "s|'CCSHARED': .*|'CCSHARED': '-fPIC',|g" "$f" 2>/dev/null || true
    sed -i "s|'LDSHARED': .*|'LDSHARED': '${CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'BLDSHARED': .*|'BLDSHARED': '${CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'LDCXXSHARED': .*|'LDCXXSHARED': '${CXX} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/lib|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/include|${TARGET_ROOT}/include|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/bin|${TARGET_ROOT}/bin|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib/x86_64-linux-gnu|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib64|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/local/lib|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/local/include|${TARGET_ROOT}/include|g" "$f" 2>/dev/null || true
done

# Copy headers
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true
fi

# Global sitecustomize
cat > "${HOST_PY_LIB}/sitecustomize.py" <<SITEEOF
import os
import sysconfig

if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'

_TR = "${TARGET_ROOT}"
_PY = "python${PYTHON_MINOR}"

_patches = {
    'LIBPL': _TR + '/lib',
    'LIBDIR': _TR + '/lib',
    'LIBDEST': _TR + '/lib/' + _PY,
    'INCLUDEPY': _TR + '/include/' + _PY,
    'CONFINCLUDEPY': _TR + '/include/' + _PY,
    'LIBRARY': 'python${PYTHON_MINOR}',
    'LDLIBRARY': 'libpython${PYTHON_MINOR}.so',
    'BLDLIBRARY': '-lpython${PYTHON_MINOR}',
    'CCSHARED': '-fPIC',
    'LDSHARED': '${CC} -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'BLDSHARED': '${CC} -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'LDCXXSHARED': '${CXX} -shared -L' + _TR + '/lib -Wl,--hash-style=both',
}

_orig_gcv = sysconfig.get_config_var
def _gcv(name):
    return _patches.get(name, _orig_gcv(name))
sysconfig.get_config_var = _gcv

_scheme = {
    'stdlib': _TR + '/lib/' + _PY,
    'platstdlib': _TR + '/lib/' + _PY,
    'purelib': _TR + '/lib/' + _PY + '/site-packages',
    'platlib': _TR + '/lib/' + _PY + '/site-packages',
    'include': _TR + '/include/' + _PY,
    'platinclude': _TR + '/include/' + _PY,
    'scripts': _TR + '/bin',
    'data': _TR,
}
_orig_get_path = sysconfig.get_path
def _new_get_path(name, scheme='posix_prefix', vars=None, expand=True):
    return _scheme.get(name, _orig_get_path(name, scheme, vars, expand))
sysconfig.get_path = _new_get_path

_orig_get_paths = sysconfig.get_paths
def _new_get_paths(scheme='posix_prefix', vars=None, expand=True):
    return dict(_scheme)
sysconfig.get_paths = _new_get_paths

try:
    if hasattr(sysconfig, '_INSTALL_SCHEMES'):
        for k in list(sysconfig._INSTALL_SCHEMES.keys()):
            sysconfig._INSTALL_SCHEMES[k] = dict(_scheme)
except Exception:
    pass
SITEEOF
echo "  ✅ Global sitecustomize: ${HOST_PY_LIB}/sitecustomize.py"

# ════════════════════════════════════════════════════════════
# [FIX] Xoá symlink libpython3.13.so của host → linker chỉ
#       tìm thấy bản target trong /work/python-android/lib
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Ẩn host libpython.so để tránh nhầm với target"
HOST_LIBPY="${HOST_PY_PREFIX}/lib/libpython${PYTHON_MINOR}.so"
if [ -L "$HOST_LIBPY" ] || [ -f "$HOST_LIBPY" ]; then
    if [ ! -f "${HOST_LIBPY}.hidden" ]; then
        mv "$HOST_LIBPY" "${HOST_LIBPY}.hidden"
        echo "  ✅ Renamed: $HOST_LIBPY → ${HOST_LIBPY}.hidden"
    fi
fi
# Remove other host lib dirs that could shadow target
for f in "${HOST_PY_PREFIX}/lib/libpython${PYTHON_MINOR}.so"*; do
    [ -f "$f" ] || continue
    case "$f" in
        *.hidden) continue ;;
        *.so.*) 
            # versioned .so.1.0 → keep (host python needs it)
            ;;
    esac
done

# ════════════════════════════════════════════════════════════
# [FIX] Tạo python3.pc cho meson dependency('python3')
# ════════════════════════════════════════════════════════════
echo "  → Tạo python3.pc cho meson"
mkdir -p "${DEPS_INSTALL}/lib/pkgconfig"
cat > "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" <<EOF
prefix=${TARGET_ROOT}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/python${PYTHON_MINOR}

Name: Python
Description: Python library
Version: ${PYTHON_VERSION}
Libs: -L\${libdir} -lpython${PYTHON_MINOR}
Libs.private: -lm -ldl
Cflags: -I\${includedir}
EOF
echo "  ✅ python3.pc created"

# Copy python3.pc vào host python pkgconfig luôn
cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" "${HOST_PY_PREFIX}/lib/pkgconfig/" 2>/dev/null || true

# ════════════════════════════════════════════════════════════
# [FIX] Verify cffi installed cho zstandard
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Verify cffi cho zstandard"
"${HOST_PYTHON}" -c "import _cffi_backend; print('  ✅ _cffi_backend OK')" 2>/dev/null || {
    echo "  ⚠️  _cffi_backend missing — reinstall cffi"
    "${HOST_PYTHON}" -m pip install --no-cache-dir --force-reinstall cffi 2>&1 | tail -5
    "${HOST_PYTHON}" -c "import _cffi_backend; print('  ✅ _cffi_backend OK after reinstall')"
}

# Verify
echo ""
echo "  Verify host python sysconfig:"
"${HOST_PYTHON}" -c "
import sysconfig
print('    CCSHARED:', sysconfig.get_config_var('CCSHARED'))
print('    LIBDIR:', sysconfig.get_config_var('LIBDIR'))
print('    INCLUDEPY:', sysconfig.get_config_var('INCLUDEPY'))
print('    get_path(include):', sysconfig.get_path('include'))
print('    get_path(purelib):', sysconfig.get_path('purelib'))
"

# Verify libpython resolution
echo "  Verify linker sẽ tìm libpython từ đâu:"
echo "    host libpython (hidden): $([ -f ${HOST_LIBPY}.hidden ] && echo 'YES' || echo 'NO')"
echo "    target libpython: $([ -f ${TARGET_ROOT}/lib/libpython${PYTHON_MINOR}.so ] && echo 'YES' || echo 'NO')"

# 4. Bootstrap pip
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo ""
    echo "🔨 Bootstrap pip..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        pip setuptools wheel || { echo "❌ Bootstrap pip FAILED"; exit 1; }
fi

# 5. Read package list
if [ -n "${INPUT_PACKAGES}" ]; then
    LIST="${INPUT_PACKAGES}"
else
    LIST=$(grep -v '^#' wheels/list.txt | grep -v '^$' | tr '\n' ' ')
fi
CLEAN=""
for p in $LIST; do
    if echo "$p" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.\-]*$'; then
        CLEAN="$CLEAN $p"
    fi
done
CLEAN=$(echo "$CLEAN" | xargs)
export PKGLIST="${CLEAN}"
echo ""
echo "📦 Packages: ${PKGLIST}"

# 6. Build wheels
bash scripts/build-wheels.sh || true

WHEEL_COUNT=$(ls "${WHEELS_OUT}"/*.whl 2>/dev/null | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo "❌ Không có wheel nào"; exit 1
fi
echo "✅ Có $WHEEL_COUNT wheel"

# 7. Post-process
bash scripts/post-process.sh || { echo "❌ Post-process FAILED"; exit 1; }

# 8. Verify
bash scripts/verify-wheels.sh || echo "⚠️  Verify có lỗi"

echo ""
echo "✅ Build complete"
ls -lh "${WHEELS_FINAL}/" || true
exit 0