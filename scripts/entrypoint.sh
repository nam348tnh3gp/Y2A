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
# 3. Setup sysconfigdata + GLOBAL sitecustomize
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Setup sysconfig cho host python"

TARGET_SYSCONF=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
[ -z "$TARGET_SYSCONF" ] && { echo "❌ Không có _sysconfigdata"; exit 1; }

SYSCONF_NAME=$(basename "$TARGET_SYSCONF" .py)
HOST_PY_LIB="${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"

echo "  Source:  $TARGET_SYSCONF"
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"

export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
echo "  _PYTHON_SYSCONFIGDATA_NAME=$SYSCONF_NAME"

for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

# Patch tất cả sysconfigdata files: host paths → target paths
echo "  Patch sysconfigdata files"
for f in "${HOST_PY_LIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    # [FIX] CCSHARED = -fPIC only (bỏ hash-style)
    sed -i "s|'CCSHARED': .*|'CCSHARED': '-fPIC',|g" "$f" 2>/dev/null || true
    # [FIX] LDSHARED có -L target
    sed -i "s|'LDSHARED': .*|'LDSHARED': '${CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'BLDSHARED': .*|'BLDSHARED': '${CC} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    sed -i "s|'LDCXXSHARED': .*|'LDCXXSHARED': '${CXX} -shared -L${TARGET_ROOT}/lib -Wl,--hash-style=both',|g" "$f" 2>/dev/null || true
    # Host paths → target
    sed -i "s|/opt/host-python/lib|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/include|${TARGET_ROOT}/include|g" "$f" 2>/dev/null || true
    sed -i "s|/opt/host-python/bin|${TARGET_ROOT}/bin|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib/x86_64-linux-gnu|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/lib64|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/local/lib|${TARGET_ROOT}/lib|g" "$f" 2>/dev/null || true
    sed -i "s|/usr/local/include|${TARGET_ROOT}/include|g" "$f" 2>/dev/null || true
    sed -i "s|'/usr/lib'|'${TARGET_ROOT}/lib'|g" "$f" 2>/dev/null || true
    sed -i "s|'/usr/include'|'${TARGET_ROOT}/include'|g" "$f" 2>/dev/null || true
done

# Copy headers
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
# [FIX] Global sitecustomize — áp dụng cho MỌI subprocess của host python
# Override: get_config_var, get_path, get_paths, _INSTALL_SCHEMES
# ════════════════════════════════════════════════════════════
HOST_SITECUSTOMIZE="${HOST_PY_LIB}/sitecustomize.py"
cat > "$HOST_SITECUSTOMIZE" <<SITEEOF
import os
import sysconfig

# Force sysconfigdata name cho subprocess không inherit env
if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'

_TARGET_ROOT = "${TARGET_ROOT}"
_PY_VER = "python${PYTHON_MINOR}"

# Patch config vars
_patches = {
    'LIBPL': _TARGET_ROOT + '/lib',
    'LIBDIR': _TARGET_ROOT + '/lib',
    'LIBDEST': _TARGET_ROOT + '/lib/' + _PY_VER,
    'INCLUDEPY': _TARGET_ROOT + '/include/' + _PY_VER,
    'CONFINCLUDEPY': _TARGET_ROOT + '/include/' + _PY_VER,
    'LIBRARY': 'python${PYTHON_MINOR}',
    'LDLIBRARY': 'libpython${PYTHON_MINOR}.so',
    'BLDLIBRARY': '-lpython${PYTHON_MINOR}',
    'CCSHARED': '-fPIC',
    'LDSHARED': '${CC} -shared -L' + _TARGET_ROOT + '/lib -Wl,--hash-style=both',
    'BLDSHARED': '${CC} -shared -L' + _TARGET_ROOT + '/lib -Wl,--hash-style=both',
    'LDCXXSHARED': '${CXX} -shared -L' + _TARGET_ROOT + '/lib -Wl,--hash-style=both',
}
_orig_gcv = sysconfig.get_config_var
def _gcv(name):
    if name in _patches:
        return _patches[name]
    return _orig_gcv(name)
sysconfig.get_config_var = _gcv

# Patch get_path
_scheme = {
    'stdlib': _TARGET_ROOT + '/lib/' + _PY_VER,
    'platstdlib': _TARGET_ROOT + '/lib/' + _PY_VER,
    'purelib': _TARGET_ROOT + '/lib/' + _PY_VER + '/site-packages',
    'platlib': _TARGET_ROOT + '/lib/' + _PY_VER + '/site-packages',
    'include': _TARGET_ROOT + '/include/' + _PY_VER,
    'platinclude': _TARGET_ROOT + '/include/' + _PY_VER,
    'scripts': _TARGET_ROOT + '/bin',
    'data': _TARGET_ROOT,
}
_orig_get_path = sysconfig.get_path
def _new_get_path(name, scheme='posix_prefix', vars=None, expand=True):
    if name in _scheme:
        return _scheme[name]
    return _orig_get_path(name, scheme, vars, expand)
sysconfig.get_path = _new_get_path

_orig_get_paths = sysconfig.get_paths
def _new_get_paths(scheme='posix_prefix', vars=None, expand=True):
    return dict(_scheme)
sysconfig.get_paths = _new_get_paths

# Patch _INSTALL_SCHEMES
try:
    if hasattr(sysconfig, '_INSTALL_SCHEMES'):
        for k in ('posix_prefix', 'posix_local', 'deb_system'):
            sysconfig._INSTALL_SCHEMES[k] = dict(_scheme)
except Exception:
    pass
SITEEOF
echo "  ✅ Global sitecustomize: $HOST_SITECUSTOMIZE"

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
" || { echo "  ❌ Verify failed"; exit 1; }

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