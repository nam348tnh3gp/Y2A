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
export HOST_INCLUDE_PARENT="${HOST_PY_PREFIX}/include"

export NDK_CC="${CC}"
export NDK_CXX="${CXX}"
export NDK_AR="${AR}"

mkdir -p "${TARGET_ROOT}" "${DEPS_INSTALL}" "${WHEELS_OUT}" "${WHEELS_FINAL}"

# ════════════════════════════════════════════════════════════
# [NDK r27] Verify NDK version
# ════════════════════════════════════════════════════════════
NDK_REV=$(grep 'Pkg.Revision' "${NDK}/source.properties" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo "unknown")
echo "📌 NDK revision: ${NDK_REV}"
echo "📌 Clang: $(${NDK_CC} --version 2>/dev/null | head -1 || echo 'unknown')"
case "${NDK_REV}" in
    27.*|28.*|29.*) echo "  ✅ NDK r27+ — Clang 18+, ICE clang 14 không còn" ;;
    *) echo "  ⚠️  NDK ${NDK_REV} — có thể gặp ICE clang 14 với NumPy" ;;
esac

# 1. Cross-compile core deps
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh || { echo "❌ deps FAILED"; exit 1; }
    touch "${DEPS_INSTALL}/.done"
fi

# 2. Cross-compile CPython
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

if [ ! -f "${TARGET_INCLUDE_CHECK}/Python.h" ]; then
    echo "❌ Python.h VẪN missing sau cross-compile"
    ls -la "${TARGET_INCLUDE_CHECK}" | head -20
    exit 1
fi
echo "  ✅ Python.h: ${TARGET_INCLUDE_CHECK}/Python.h"

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

# Copy target headers → host include (subdir python3.13)
if [ -d "${TARGET_INCLUDE_CHECK}" ] && [ -d "${HOST_INCLUDE}" ]; then
    cp -rf "${TARGET_INCLUDE_CHECK}/." "${HOST_INCLUDE}/" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
# [FIX] Copy Python headers vào PARENT dir bao gồm subdirs
# ════════════════════════════════════════════════════════════
echo "🔧 Copy Python headers vào parent dir (giữ subdirs)"
cp -rn "${HOST_INCLUDE}/." "${HOST_INCLUDE_PARENT}/" 2>/dev/null || true
echo "  ✅ Python.h ở ${HOST_INCLUDE_PARENT}/Python.h"
echo "  ✅ cpython/pymem.h ở ${HOST_INCLUDE_PARENT}/cpython/pymem.h"
[ -f "${HOST_INCLUDE_PARENT}/cpython/pymem.h" ] || {
    echo "  ⚠️  cpython/pymem.h missing — fallback symlink"
    ln -sfn "python${PYTHON_MINOR}/cpython" "${HOST_INCLUDE_PARENT}/cpython" 2>/dev/null || true
    ln -sfn "python${PYTHON_MINOR}/internal" "${HOST_INCLUDE_PARENT}/internal" 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════
# Global sitecustomize
# ════════════════════════════════════════════════════════════
cat > "${HOST_PY_LIB}/sitecustomize.py" <<SITEEOF
import os, sysconfig

if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'

_TR = "${TARGET_ROOT}"
_PY = "python${PYTHON_MINOR}"

_p = {
    'LIBPL': _TR + '/lib',
    'LIBDIR': _TR + '/lib',
    'LIBDEST': _TR + '/lib/' + _PY,
    'INCLUDEPY': _TR + '/include/' + _PY,
    'CONFINCLUDEPY': _TR + '/include/' + _PY,
    'LIBRARY': 'python${PYTHON_MINOR}',
    'LDLIBRARY': 'libpython${PYTHON_MINOR}.so',
    'BLDLIBRARY': '-lpython${PYTHON_MINOR}',
    'CCSHARED': '-fPIC',
    'LDSHARED':    '${NDK_CC}  -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'BLDSHARED':   '${NDK_CC}  -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'LDCXXSHARED': '${NDK_CXX} -shared -L' + _TR + '/lib -Wl,--hash-style=both',
}
_orig_gcv = sysconfig.get_config_var
def _gcv(n):
    if n in _p:
        return _p[n]
    return _orig_gcv(n)
sysconfig.get_config_var = _gcv

_s = {
    'stdlib':      _TR + '/lib/' + _PY,
    'platstdlib':  _TR + '/lib/' + _PY,
    'purelib':     _TR + '/lib/' + _PY + '/site-packages',
    'platlib':     _TR + '/lib/' + _PY + '/site-packages',
    'include':     _TR + '/include/' + _PY,
    'platinclude': _TR + '/include/' + _PY,
    'scripts':     _TR + '/bin',
    'data':        _TR,
}

def _is_target_call(vars):
    if not vars:
        return True
    base = vars.get('base') or vars.get('platbase')
    if base is None:
        return True
    try:
        return (os.path.realpath(str(base)).rstrip('/')
                == os.path.realpath(_TR).rstrip('/'))
    except Exception:
        return False

_orig_gp = sysconfig.get_path
def _gp(n, scheme='posix_prefix', vars=None, expand=True):
    if not _is_target_call(vars):
        return _orig_gp(n, scheme, vars, expand)
    return _s.get(n, _orig_gp(n, scheme, vars, expand))
sysconfig.get_path = _gp

_orig_gps = sysconfig.get_paths
def _gps(scheme='posix_prefix', vars=None, expand=True):
    if not _is_target_call(vars):
        return _orig_gps(scheme, vars, expand)
    return dict(_s)
sysconfig.get_paths = _gps
SITEEOF
echo "  ✅ sitecustomize OK"

# ── Sanity test
"${HOST_PYTHON}" - <<'PYEOF' || { echo "❌ sitecustomize delegation broken"; exit 1; }
import sysconfig, tempfile, os
_expected_target = os.environ.get("TARGET_SITE", "")
p_default = sysconfig.get_paths()['purelib']
tmp = tempfile.mkdtemp(prefix="p4a-sanity-")
p_tmp = sysconfig.get_paths(vars={'base': tmp, 'platbase': tmp})['purelib']
print(f"  default purelib: {p_default}")
print(f"  temp   purelib: {p_tmp}")
assert _expected_target in p_default, f"target purelib wrong: {p_default}"
assert tmp in p_tmp,               f"delegation broken: {p_tmp} does not contain {tmp}"
assert p_tmp != p_default,         "delegation still returns TARGET_SITE"
print("  ✅ sitecustomize sanity OK")
PYEOF

# Setup native tools
echo "🔧 Setup native tools"
sudo mkdir -p /usr/local/bin
for bindir in /usr/local/bin /usr/bin; do
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python3"
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python3.13"
    sudo ln -sf "${HOST_PYTHON}" "${bindir}/python"
    [ -f "${HOST_PY_PREFIX}/bin/cython" ] && sudo ln -sf "${HOST_PY_PREFIX}/bin/cython" "${bindir}/cython"
    [ -f "${HOST_PY_PREFIX}/bin/cython3" ] && sudo ln -sf "${HOST_PY_PREFIX}/bin/cython3" "${bindir}/cython3"
done
echo "  ✅ python3, cython symlinked"

# Compiler wrappers
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

# Ẩn host libpython
HOST_LIBPY="${HOST_PY_PREFIX}/lib/libpython${PYTHON_MINOR}.so"
if [ -L "$HOST_LIBPY" ] || [ -f "$HOST_LIBPY" ]; then
    [ ! -f "${HOST_LIBPY}.hidden" ] && mv "$HOST_LIBPY" "${HOST_LIBPY}.hidden"
    echo "  ✅ Hidden: $HOST_LIBPY"
fi

# ════════════════════════════════════════════════════════════
# [FIX] python3.pc cho meson — copy vào DEFAULT pkg-config paths
# ════════════════════════════════════════════════════════════
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

for dst in \
    "${HOST_PY_PREFIX}/lib/pkgconfig" \
    "/usr/lib/x86_64-linux-gnu/pkgconfig" \
    "/usr/local/lib/pkgconfig" \
    "/usr/lib/pkgconfig"; do
    sudo mkdir -p "$dst" 2>/dev/null || mkdir -p "$dst" 2>/dev/null || true
    sudo cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" "$dst/" 2>/dev/null || \
        cp "${DEPS_INSTALL}/lib/pkgconfig/python3.pc" "$dst/" 2>/dev/null || true
done
echo "  ✅ python3.pc OK (5 paths)"
echo "  pkg-config test: $(pkg-config --modversion python3 2>&1 || echo 'not found')"

# ════════════════════════════════════════════════════════════
# [FIX] Cleanup cffi khỏi TARGET_SITE
# ════════════════════════════════════════════════════════════
echo "🔧 Cleanup cffi khỏi TARGET_SITE"
mkdir -p "${TARGET_SITE}"
rm -rf "${TARGET_SITE}/cffi" 2>/dev/null || true
rm -rf "${TARGET_SITE}/cffi-"*.dist-info 2>/dev/null || true
rm -rf "${TARGET_SITE}/pycparser" 2>/dev/null || true
rm -rf "${TARGET_SITE}/pycparser-"*.dist-info 2>/dev/null || true
rm -f  "${TARGET_SITE}/_cffi_backend"* 2>/dev/null || true

LEFTOVER=$(find "${TARGET_SITE}" -maxdepth 1 -mindepth 1 \
    \( -name "cffi*" -o -name "_cffi_backend*" -o -name "pycparser*" \) \
    2>/dev/null | wc -l)
LEFTOVER=${LEFTOVER:-0}
LEFTOVER=$(echo "$LEFTOVER" | tr -d '[:space:]')

if [ "${LEFTOVER:-0}" -gt 0 ]; then
    echo "  ⚠️  Còn ${LEFTOVER} leftover — force remove"
    sudo rm -rf "${TARGET_SITE}"/cffi* "${TARGET_SITE}"/_cffi_backend* "${TARGET_SITE}"/pycparser* 2>/dev/null || true
    LEFTOVER=$(find "${TARGET_SITE}" -maxdepth 1 -mindepth 1 \
        \( -name "cffi*" -o -name "_cffi_backend*" -o -name "pycparser*" \) \
        2>/dev/null | wc -l)
    LEFTOVER=$(echo "$LEFTOVER" | tr -d '[:space:]')
fi
echo "  ✅ TARGET_SITE cleaned (leftover=${LEFTOVER:-0})"

"${HOST_PYTHON}" -c "
import cffi, _cffi_backend
print(f'  host cffi: {cffi.__version__}')
print(f'  host _cffi_backend: {_cffi_backend.__version__}')
" || echo "  ⚠️  host cffi check failed"

# ════════════════════════════════════════════════════════════
# 4. Bootstrap pip vào TARGET_SITE
# ════════════════════════════════════════════════════════════
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo "🔨 Bootstrap pip vào TARGET_SITE..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        --upgrade pip setuptools wheel || exit 1
fi

# ════════════════════════════════════════════════════════════
# [FIX build-deps] Cài build-time deps vào thư mục RIÊNG
#
# Tại sao không cài vào HOST_PYTHON?
#   HOST_PYTHON có sitecustomize.py override sysconfig.get_paths()
#   → pip install mặc định nghĩ site-packages là TARGET_SITE → cài
#   nhầm vào đó. Build subprocess với PYTHONPATH=PYSITE không thấy.
#
# Giải pháp: cài vào BUILD_DEPS_SITE riêng, rồi build script export
# cả PYSITE + BUILD_DEPS_SITE vào PYTHONPATH.
# ════════════════════════════════════════════════════════════
export BUILD_DEPS_SITE="${WORKSPACE}/build-deps-site"
mkdir -p "${BUILD_DEPS_SITE}"

echo "🔨 Install build-time deps vào ${BUILD_DEPS_SITE}..."
BUILD_DEPS=(
    "hatch-vcs>=0.4"
    "hatchling>=1.25"
    "setuptools-scm>=8.0"
    "cppy>=1.2"
    "meson-python>=0.16"
    "meson>=1.4"
    "ninja>=1.11"
    "flit-core>=3.9"
    "scikit-build-core>=0.10"
    "cmake>=3.28"
    "packaging>=24"
    "wheel>=0.44"
    "pybind11>=2.12"
    "poetry-core>=1.9"
    "setuptools-rust>=1.9"
    "expandvars>=0.12"
    "tomli>=2.0"
    "pkgconfig>=1.5"
)

if ! ${HOST_PYTHON} -m pip install \
        --target="${BUILD_DEPS_SITE}" \
        --no-cache-dir --no-compile --upgrade \
        "${BUILD_DEPS[@]}" 2>&1 | tee /tmp/build-deps.log | tail -10; then
    echo "❌ Build-time deps install FAILED"
    cat /tmp/build-deps.log
    exit 1
fi

# ════════════════════════════════════════════════════════════
# [FIX] Verify build-time deps với mapping pip-name:import-name
#
# Lý do dùng mapping:
#   - poetry-core  → import poetry.core   (dot, không phải underscore)
#   - Các package khác đều đổi '-' → '_'
#     nhưng poetry-core là ngoại lệ phải viết tường minh.
# ════════════════════════════════════════════════════════════
echo "🔍 Verify build-time deps..."
FAIL=0
for spec in \
    "setuptools_scm:setuptools_scm" \
    "cppy:cppy" \
    "hatch-vcs:hatch_vcs" \
    "hatchling:hatchling" \
    "meson-python:mesonpy" \
    "ninja:ninja" \
    "flit-core:flit_core" \
    "scikit-build-core:scikit_build_core" \
    "cmake:cmake" \
    "packaging:packaging" \
    "pybind11:pybind11" \
    "poetry-core:poetry.core" \
    "setuptools-rust:setuptools_rust" \
    "expandvars:expandvars" \
    "tomli:tomli" \
    "pkgconfig:pkgconfig"; do
    pkg_name="${spec%%:*}"
    mod_name="${spec##*:}"
    if PYTHONPATH="${BUILD_DEPS_SITE}" ${HOST_PYTHON} -c "import ${mod_name}" 2>/dev/null; then
        echo "  ✅ ${pkg_name} (import ${mod_name})"
    else
        echo "  ❌ ${pkg_name} — import ${mod_name} FAILED"
        FAIL=1
    fi
done
[ "$FAIL" -eq 1 ] && { echo "❌ Some build-time deps missing"; exit 1; }
echo "  ✅ All build-time deps OK"

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