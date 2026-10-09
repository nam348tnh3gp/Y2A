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
export HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
export HOST_SITE="${HOST_PY_LIB}/site-packages"

# [FIX] Capture NDK compiler cho cc-rs
export NDK_CC="${CC}"
export NDK_CXX="${CXX}"
export NDK_AR="${AR}"

mkdir -p "${TARGET_ROOT}" "${DEPS_INSTALL}" "${WHEELS_OUT}" "${WHEELS_FINAL}"

# 1. Cross-compile core deps
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh || { echo "❌ deps FAILED"; exit 1; }
    touch "${DEPS_INSTALL}/.done"
fi

# 2. Cross-compile CPython
# [FIX] Verify Python.h tồn tại — nếu không, force rebuild
TARGET_INCLUDE_CHECK="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
if [ ! -f "${TARGET_INCLUDE_CHECK}/Python.h" ]; then
    echo "⚠️  Python.h missing tại ${TARGET_INCLUDE_CHECK} — force cross-compile"
    rm -f "${TARGET_ROOT}/.python-built"
fi

if [ ! -f "${TARGET_ROOT}/.python-built" ]; then
    echo "🔨 Cross-compile CPython..."
    bash scripts/cross-compile-python.sh || { echo "❌ python FAILED"; exit 1; }
    touch "${TARGET_ROOT}/.python-built"
fi

# Verify sau build
if [ ! -f "${TARGET_INCLUDE_CHECK}/Python.h" ]; then
    echo "❌ Python.h VẪN missing sau cross-compile — dừng"
    ls -la "${TARGET_INCLUDE_CHECK}" | head -20
    exit 1
fi
echo "  ✅ Python.h có mặt: ${TARGET_INCLUDE_CHECK}/Python.h"

# ════════════════════════════════════════════════════════════
# 3. Setup sysconfig
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Setup sysconfig"

TARGET_SYSCONF=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
[ -z "$TARGET_SYSCONF" ] && { echo "❌ No _sysconfigdata"; exit 1; }
SYSCONF_NAME=$(basename "$TARGET_SYSCONF" .py)
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"
export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"

for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] && cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

for f in "${HOST_PY_LIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    sed -i "s|'CCSHARED': .*|'CCSHARED': '-fPIC',|g" "$f" 2>/dev/null || true
    sed -i "s|'LDSHARED': .*|'LDSHARED': '${NDK_CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'BLDSHARED': .*|'BLDSHARED': '${NDK_CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'LDCXXSHARED': .*|'LDCXXSHARED': '${NDK_CXX} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/lib|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/include|${TARGET_ROOT}/include|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib/x86_64-linux-gnu|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib64|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
done

# Copy headers
if [ -d "${TARGET_INCLUDE_CHECK}" ] && [ -d "${HOST_INCLUDE}" ]; then
    cp -rf "${TARGET_INCLUDE_CHECK}/." "${HOST_INCLUDE}/" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
# [FIX] Symlink tất cả Python headers vào /opt/host-python/include/
# (parent dir) để compile với -I/opt/host-python/include cũng tìm thấy
# ════════════════════════════════════════════════════════════
echo "🔧 Symlink Python headers lên parent dir"
HOST_INCLUDE_PARENT="${HOST_PY_PREFIX}/include"
for h in "${HOST_INCLUDE}"/*.h; do
    [ -f "$h" ] || continue
    ln -sf "python${PYTHON_MINOR}/$(basename "$h")" "${HOST_INCLUDE_PARENT}/$(basename "$h")"
done
echo "  ✅ Symlinked $(ls "${HOST_INCLUDE}"/*.h 2>/dev/null | wc -l) headers → ${HOST_INCLUDE_PARENT}/"

# Verify
if [ ! -f "${HOST_INCLUDE_PARENT}/Python.h" ]; then
    echo "❌ Python.h symlink FAILED"
    exit 1
fi
echo "  ✅ ${HOST_INCLUDE_PARENT}/Python.h OK"

# Global sitecustomize
cat > "${HOST_PY_LIB}/sitecustomize.py" <<SITEEOF
import os, sysconfig
if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'
_TR = "${TARGET_ROOT}"
_PY = "python${PYTHON_MINOR}"
_p = {'LIBPL': _TR+'/lib', 'LIBDIR': _TR+'/lib', 'LIBDEST': _TR+'/lib/'+_PY,
      'INCLUDEPY': _TR+'/include/'+_PY, 'CONFINCLUDEPY': _TR+'/include/'+_PY,
      'LIBRARY': 'python${PYTHON_MINOR}', 'LDLIBRARY': 'libpython${PYTHON_MINOR}.so',
      'BLDLIBRARY': '-lpython${PYTHON_MINOR}', 'CCSHARED': '-fPIC',
      'LDSHARED': '${NDK_CC} -shared -L'+_TR+'/lib -Wl,--hash-style=both',
      'BLDSHARED': '${NDK_CC} -shared -L'+_TR+'/lib -Wl,--hash-style=both',
      'LDCXXSHARED': '${NDK_CXX} -shared -L'+_TR+'/lib -Wl,--hash-style=both'}
_orig = sysconfig.get_config_var
def _gcv(n): return _p.get(n, _orig(n))
sysconfig.get_config_var = _gcv
_s = {'stdlib': _TR+'/lib/'+_PY, 'platstdlib': _TR+'/lib/'+_PY,
      'purelib': _TR+'/lib/'+_PY+'/site-packages',
      'platlib': _TR+'/lib/'+_PY+'/site-packages',
      'include': _TR+'/include/'+_PY, 'platinclude': _TR+'/include/'+_PY,
      'scripts': _TR+'/bin', 'data': _TR}
_ogp = sysconfig.get_path
def _gp(n, *a, **kw): return _s.get(n, _ogp(n, *a, **kw))
sysconfig.get_path = _gp
_ogps = sysconfig.get_paths
def _gps(scheme='posix_prefix', vars=None, expand=True): return dict(_s)
sysconfig.get_paths = _gps
try:
    if hasattr(sysconfig, '_INSTALL_SCHEMES'):
        for k in list(sysconfig._INSTALL_SCHEMES.keys()):
            sysconfig._INSTALL_SCHEMES[k] = dict(_s)
except Exception: pass
SITEEOF
echo "  ✅ sitecustomize OK"

# ════════════════════════════════════════════════════════════
# [FIX] Symlink python3, cython vào CẢ /usr/local/bin VÀ /usr/bin
# ════════════════════════════════════════════════════════════
echo "🔧 Setup native tools"
sudo mkdir -p /usr/local/bin
for bindir in /usr/local/bin /usr/bin; do
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python3"
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python3.13"
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python"
    [ -f "${HOST_PY_PREFIX}/bin/cython" ] && sudo ln -sf "${HOST_PY_PREFIX}/bin/cython" "${bindir}/cython"
    [ -f "${HOST_PY_PREFIX}/bin/cython3" ] && sudo ln -sf "${HOST_PY_PREFIX}/bin/cython3" "${bindir}/cython3"
done
echo "  ✅ python3, python3.13, python, cython, cython3 symlinked"

# ════════════════════════════════════════════════════════════
# [FIX] Compiler wrapper aarch64-linux-android-* trong /usr/local/bin
# ════════════════════════════════════════════════════════════
echo "🔧 Compiler wrappers"
for tool in gcc g++ ar ranlib strip; do
    case $tool in
        gcc) real="${NDK_CC}" ;;
        g++) real="${NDK_CXX}" ;;
        ar) real="${NDK_AR}" ;;
        ranlib) real="${RANLIB}" ;;
        strip) real="${STRIP}" ;;
    esac
    sudo tee "/usr/local/bin/aarch64-linux-android-${tool}" > /dev/null <<EOF
#!/bin/sh
exec "${real}" "\$@"
EOF
    sudo chmod +x "/usr/local/bin/aarch64-linux-android-${tool}"
    sudo ln -sf "/usr/local/bin/aarch64-linux-android-${tool}" "/usr/bin/aarch64-linux-android-${tool}"
done
echo "  ✅ aarch64-linux-android-{gcc,g++,ar,ranlib,strip} OK"

# ════════════════════════════════════════════════════════════
# [FIX] Ẩn host libpython3.13.so
# ════════════════════════════════════════════════════════════
HOST_LIBPY="${HOST_PY_PREFIX}/lib/libpython${PYTHON_MINOR}.so"
if [ -L "$HOST_LIBPY" ] || [ -f "$HOST_LIBPY" ]; then
    [ ! -f "${HOST_LIBPY}.hidden" ] && mv "$HOST_LIBPY" "${HOST_LIBPY}.hidden"
    echo "  ✅ Hidden: $HOST_LIBPY"
fi

# ════════════════════════════════════════════════════════════
# [FIX] python3.pc cho meson — tạo ở nhiều path
# ════════════════════════════════════════════════════════════
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
# Copy vào system pkg-config paths
sudo mkdir -p /usr/local/lib/pkgconfig /usr/lib/pkgconfig
sudo cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" /usr/local/lib/pkgconfig/ 2>/dev/null || true
sudo cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" /usr/lib/pkgconfig/ 2>/dev/null || true
mkdir -p "${HOST_PY_PREFIX}/lib/pkgconfig"
cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" "${HOST_PY_PREFIX}/lib/pkgconfig/" 2>/dev/null || true
echo "  ✅ python3.pc OK (3 paths)"

# ════════════════════════════════════════════════════════════
# [FIX] Force xoá cffi khỏi TARGET_SITE (đề phòng cache cũ)
# ════════════════════════════════════════════════════════════
echo "🔧 Cleanup cffi khỏi TARGET_SITE"
mkdir -p "${TARGET_SITE}"
find "${TARGET_SITE}" -maxdepth 1 -name "cffi*" -exec rm -rf {} \; 2>/dev/null || true
find "${TARGET_SITE}" -maxdepth 1 -name "_cffi_backend*" -exec rm -rf {} \; 2>/dev/null || true
find "${TARGET_SITE}" -maxdepth 1 -name "pycparser*" -exec rm -rf {} \; 2>/dev/null || true

# Verify
REMAINING=$(find "${TARGET_SITE}" -maxdepth 1 \( -name "cffi*" -o -name "_cffi_backend*" -o -name "pycparser*" \) 2>/dev/null | wc -l)
if [ "$REMAINING" -gt 0 ]; then
    echo "  ⚠️  Còn $REMAINING cffi files — force delete lại"
    find "${TARGET_SITE}" -maxdepth 1 \( -name "cffi*" -o -name "_cffi_backend*" -o -name "pycparser*" \) -exec rm -rf {} \; 2>/dev/null || true
fi
echo "  ✅ TARGET_SITE cleaned"

# Verify host cffi
"${HOST_PYTHON}" -c "
import cffi, _cffi_backend
print(f'  host cffi: {cffi.__version__}')
print(f'  host _cffi_backend: {_cffi_backend.__version__}')
" || echo "  ⚠️  host cffi check failed"

# 4. Bootstrap pip
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo "🔨 Bootstrap pip..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        pip setuptools wheel || exit 1
fi

# 5. Package list
if [ -n "${INPUT_PACKAGES}" ]; then LIST="${INPUT_PACKAGES}"
else LIST=$(grep -v '^#' wheels/list.txt | grep -v '^$' | tr '\n' ' '); fi
CLEAN=""
for p in $LIST; do
    echo "$p" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.\-]*$' && CLEAN="$CLEAN $p"
done
CLEAN=$(echo "$CLEAN" | xargs)
export PKGLIST="${CLEAN}"
echo "📦 Packages: ${PKGLIST}"

# 6. Build
bash scripts/build-wheels.sh || true

WHEEL_COUNT=$(ls "${WHEELS_OUT}"/*.whl 2>/dev/null | wc -l)
[ "$WHEEL_COUNT" -eq 0 ] && { echo "❌ No wheels"; exit 1; }

bash scripts/post-process.sh || exit 1
bash scripts/verify-wheels.sh || echo "⚠️  Verify có lỗi"

echo "✅ Build complete"
exit 0