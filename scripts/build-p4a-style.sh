#!/bin/bash
# build-p4a-style.sh
set -eo pipefail

PKG_SPEC="${1:-}"
[ -z "$PKG_SPEC" ] && { echo "❌ Missing pkg"; exit 1; }
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

# ════════════════════════════════════════════════════════════
# [ABI3] Danh sách package hỗ trợ Py_LIMITED_API / PyO3-abi3.
# ════════════════════════════════════════════════════════════
ABI3_TARGET="${ABI3_TARGET:-}"
ABI3_CANDIDATES="cryptography bcrypt nh3 pydantic-core cffi"
USE_ABI3=0
if [ -n "$ABI3_TARGET" ]; then
    for _c in $ABI3_CANDIDATES; do
        if [ "$PKG_NAME" = "$_c" ]; then
            USE_ABI3=1
            break
        fi
    done
fi
if [ "$USE_ABI3" -eq 1 ]; then
    echo "  🔗 ABI3: ${ABI3_TARGET} → wheel tương thích Python ≥ ${ABI3_TARGET#cp}"
else
    echo "  📦 Build native cho Python ${PYTHON_MINOR}"
fi

TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
PYSITE="${TMP_BUILD}/pysite"
LOG="/tmp/p4a-${PKG_NAME}.log"

rm -rf "$TMP_BUILD"
mkdir -p "$SRC_DIR" "${TMP_BUILD}/bin" "$PYSITE"

echo "  Building: $PKG_SPEC"
echo "  PKG_NAME: $PKG_NAME"

# ── [orjson] Hard skip ──
case "$PKG_NAME" in
    orjson)
        echo "  ⏭️  orjson: skip (x86-only SIMD code) — pin orjson<3.13 trong list.txt"
        exit 0
        ;;
esac

# Symlink python tools
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python3"
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python"
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python3.13"
[ -f "${HOST_PY_PREFIX}/bin/cython" ] && ln -sf "${HOST_PY_PREFIX}/bin/cython" "${TMP_BUILD}/bin/cython"
[ -f "${HOST_PY_PREFIX}/bin/cython3" ] && ln -sf "${HOST_PY_PREFIX}/bin/cython3" "${TMP_BUILD}/bin/cython3"

# 1. Tải source
cd "$SRC_DIR"
if ! "${HOST_PYTHON}" -m pip download "$PKG_SPEC" \
        --no-deps --no-binary=:all: --dest="$SRC_DIR" > /tmp/dl.log 2>&1; then
    echo "⚠️  pip download failed — fetch sdist từ PyPI JSON"
    PKG_BASE="${PKG_SPEC%%[<>=!~]*}"
    PYPI_JSON=$(curl -sL "https://pypi.org/pypi/${PKG_BASE}/json" 2>/dev/null || echo "{}")
    SDIST_URL=$(echo "$PYPI_JSON" | "${HOST_PYTHON}" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for u in d.get('urls', []):
        if u.get('packagetype') == 'sdist':
            print(u['url']); break
except Exception: pass
" 2>/dev/null || echo "")
    [ -z "$SDIST_URL" ] && { echo "❌ No sdist"; exit 1; }
    wget -q "$SDIST_URL" -O "${SRC_DIR}/$(basename "$SDIST_URL")" || exit 1
fi

TARBALL=$(find "$SRC_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.xz" \
    -o -name "*.tar.bz2" -o -name "*.zip" \) | head -1)
[ -z "$TARBALL" ] && { echo "❌ No source"; exit 1; }

mkdir -p "${SRC_DIR}/extracted"
tar -xf "$TARBALL" -C "${SRC_DIR}/extracted"
SRC_PATH=$(find "${SRC_DIR}/extracted" -maxdepth 1 -type d | tail -n +2 | head -1)
[ -z "$SRC_PATH" ] && SRC_PATH="${SRC_DIR}/extracted"
echo "  Source: $SRC_PATH"

# 2. Detect backend
BACKEND=$(SRC_PATH="$SRC_PATH" "${HOST_PYTHON}" - <<'PYEOF'
import tomllib, os
src = os.environ.get("SRC_PATH", ".")
try:
    with open(os.path.join(src, "pyproject.toml"), "rb") as f:
        d = tomllib.load(f)
    print(d.get("build-system", {}).get("build-backend", "setuptools"))
except Exception:
    print("setuptools")
PYEOF
)
echo "  Backend: $BACKEND"

# 3. numpy-config
cat > "${TMP_BUILD}/numpy-config" <<NCEOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
  "${HOST_PYTHON}" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo "0.0.0"
else
  echo "-I${TARGET_SITE}/numpy/_core/include"
fi
NCEOF
chmod +x "${TMP_BUILD}/numpy-config"

# 4. Sandbox
SANDBOX="${TMP_BUILD}/sandbox-bin"
mkdir -p "$SANDBOX"
mk() {
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$2" > "$SANDBOX/$1"
    chmod +x "$SANDBOX/$1"
}
for n in gcc cc clang x86_64-linux-gnu-gcc aarch64-linux-gnu-gcc; do mk "$n" "${NDK_CC}"; done
for n in g++ c++ clang++ x86_64-linux-gnu-g++ aarch64-linux-gnu-g++; do mk "$n" "${NDK_CXX}"; done
mk ar "${NDK_AR}"
mk ranlib "${RANLIB}"
mk strip "${STRIP}"
mk readelf "${READELF}"

USE_SANDBOX=1
case "$PKG_NAME" in
    cryptography|bcrypt|nh3|pydantic-core|tokenizers)
        USE_SANDBOX=0
        ;;
esac

if [ "$USE_SANDBOX" -eq 1 ]; then
    export PATH="${TMP_BUILD}/bin:${SANDBOX}:${TMP_BUILD}:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:/usr/local/bin:/usr/bin:${PATH}"
else
    export PATH="${TMP_BUILD}/bin:${TMP_BUILD}:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:/usr/local/bin:/usr/bin:${PATH}"
fi

# 5. Env
export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
export _PYTHON_PROJECT_BASE="${TARGET_ROOT}"
export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"

if [ -z "${_PYTHON_SYSCONFIGDATA_NAME:-}" ]; then
    _SC=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
    [ -n "$_SC" ] && export _PYTHON_SYSCONFIGDATA_NAME="$(basename "$_SC" .py)"
fi

unset FC F77 F90

export CC="${NDK_CC}" CXX="${NDK_CXX}" AR="${NDK_AR}" RANLIB="${RANLIB}" STRIP="${STRIP}"
export CPP="${NDK_CC} -E" LD="${NDK_CC}" AS="${NDK_CC}"

export CC_aarch64_linux_android="${NDK_CC}"
export CXX_aarch64_linux_android="${NDK_CXX}"
export AR_aarch64_linux_android="${NDK_AR}"
export CFLAGS_aarch64_linux_android="-fPIC -O2 -I${TARGET_ROOT}/include/python${PYTHON_MINOR} -I${DEPS_INSTALL}/include -Wno-implicit-function-declaration"
export LDFLAGS_aarch64_linux_android="-L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -Wl,--hash-style=both"

export LDSHARED="${NDK_CC} -shared -L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -Wl,--hash-style=both"
export CCSHARED="-fPIC"
export BLDSHARED="${NDK_CC} -shared -L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -Wl,--hash-style=both"
export LDCXXSHARED="${NDK_CXX} -shared -L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -Wl,--hash-style=both"

export LDFLAGS="-L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -L${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API}"

export CMAKE_C_COMPILER="${NDK_CC}"
export CMAKE_CXX_COMPILER="${NDK_CXX}"
export CMAKE_AR="${NDK_AR}"
export CMAKE_RANLIB="${RANLIB}"
export CMAKE_SYSTEM_NAME="Android"
export CMAKE_SYSTEM_PROCESSOR="aarch64"
export CMAKE_ANDROID_API="${ANDROID_API}"
export CMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake"
export ANDROID_ABI="arm64-v8a"
export ANDROID_PLATFORM="android-${ANDROID_API}"

# ── [uvloop / autoconf] cross env ──
export CONFIG_SITE="${TMP_BUILD}/config.site"
cat > "$CONFIG_SITE" <<EOF
host_alias=aarch64-linux-android
build_alias=x86_64-pc-linux-gnu
target_alias=aarch64-linux-android
EOF

export ac_cv_host="aarch64-linux-android"
export ac_cv_build="x86_64-pc-linux-gnu"
export ac_cv_target="aarch64-linux-android"
export cross_compiling="yes"
export HOSTCC="/usr/bin/gcc"
export HOSTCXX="/usr/bin/g++"
export CC_FOR_BUILD="/usr/bin/gcc"
export CXX_FOR_BUILD="/usr/bin/g++"
export AR_FOR_BUILD="/usr/bin/ar"
export RANLIB_FOR_BUILD="/usr/bin/ranlib"

# pkg-config
export PKG_CONFIG="${PKG_CONFIG:-/usr/bin/pkg-config}"
export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig:${DEPS_INSTALL}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_SYSROOT_DIR

case "$PKG_NAME" in
    numpy|scipy)
        export CFLAGS="-O1 -fno-vectorize -fno-slp-vectorize"
        export CXXFLAGS="-O1 -fno-vectorize -fno-slp-vectorize"
        echo "  → NumPy/SciPy: CFLAGS=$CFLAGS"
        ;;
esac

export NPY_DISABLE_SVML=1
export NPY_USE_BLAS_ILP64=0
export NPY_BLAS_LIBS="-lopenblas"
export NPY_CBLAS_LIBS="-lopenblas"
export NPY_LAPACK_LIBS="-lopenblas"

# PyO3 config
PYO3_CONFIG="${TMP_BUILD}/pyo3-config.txt"
cat > "$PYO3_CONFIG" <<EOF
implementation=CPython
version=${PYTHON_MINOR}
shared=true
abi3=true
lib_name=python${PYTHON_MINOR}
lib_dir=${TARGET_ROOT}/lib
executable=${TARGET_ROOT}/bin/python${PYTHON_MINOR}
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
EOF
export PYO3_CONFIG_FILE="$PYO3_CONFIG"

export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include/python${PYTHON_MINOR}"

# ── [numpy] GHI ĐÈ host sitecustomize ──
cat > "${HOST_PY_LIB}/sitecustomize.py" <<SITEEOF
import os, sysconfig as _sc

_TR = "${TARGET_ROOT}"
_PY = "python${PYTHON_MINOR}"

_p = {
    'LIBPL': _TR + '/lib',
    'LIBDIR': _TR + '/lib',
    'LIBDEST': _TR + '/lib/' + _PY,
    'INCLUDEPY': _TR + '/include/' + _PY,
    'CONFINCLUDEPY': _TR + '/include/' + _PY,
    'LIBRARY': _PY,
    'LDLIBRARY': 'lib' + _PY + '.so',
    'BLDLIBRARY': '-l' + _PY,
    'CCSHARED': '-fPIC',
    'LDSHARED':    '${NDK_CC}  -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'BLDSHARED':   '${NDK_CC}  -shared -L' + _TR + '/lib -Wl,--hash-style=both',
    'LDCXXSHARED': '${NDK_CXX} -shared -L' + _TR + '/lib -Wl,--hash-style=both',
}

try:
    _vars = _sc.get_config_vars()
    if isinstance(_vars, dict):
        _vars.update(_p)
    try:
        _sc._CONFIG_VARS.update(_p)
    except Exception:
        pass
except Exception as e:
    print("[sitecustomize] _CONFIG_VARS patch failed:", e,
          file=__import__('sys').stderr)

_orig_gcv = _sc.get_config_var
def _gcv(n):
    if n in _p:
        return _p[n]
    return _orig_gcv(n)
_sc.get_config_var = _gcv

_orig_gcvs = _sc.get_config_vars
def _gcvs(*names):
    if not names:
        d = dict(_orig_gcvs()); d.update(_p); return d
    return [_p.get(n, v) for n, v in zip(names, _orig_gcvs(*names))]
_sc.get_config_vars = _gcvs

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
    if not vars: return True
    base = vars.get('base') or vars.get('platbase')
    if base is None: return True
    try:
        return (os.path.realpath(str(base)).rstrip('/')
                == os.path.realpath(_TR).rstrip('/'))
    except Exception:
        return False

_orig_gp = _sc.get_path
def _gp(n, scheme='posix_prefix', vars=None, expand=True):
    if not _is_target_call(vars):
        return _orig_gp(n, scheme, vars, expand)
    return _s.get(n, _orig_gp(n, scheme, vars, expand))
_sc.get_path = _gp

_orig_gps = _sc.get_paths
def _gps(scheme='posix_prefix', vars=None, expand=True):
    if not _is_target_call(vars):
        return _orig_gps(scheme, vars, expand)
    return dict(_s)
_sc.get_paths = _gps
SITEEOF
echo "  ✅ Overwrote host sitecustomize"

"${HOST_PYTHON}" - <<'PYEOF' || { echo "❌ host sitecustomize verify failed"; exit 1; }
import sysconfig
v_s = sysconfig.get_config_var('BLDLIBRARY')
v_p = sysconfig.get_config_vars().get('BLDLIBRARY')
print(f"    [host verify] get_config_var  = {v_s!r}")
print(f"    [host verify] get_config_vars = {v_p!r}")
assert v_s and '$(BLDLIBRARY)' not in str(v_s), f"singular bad: {v_s!r}"
assert v_p and '$(BLDLIBRARY)' not in str(v_p), f"plural bad: {v_p!r}"
PYEOF

# ═══ [FIX] Copy sitecustomize THẬT vào PYSITE (che file rỗng) ═══
cp "${HOST_PY_LIB}/sitecustomize.py" "${PYSITE}/sitecustomize.py"

# PYTHONPATH
_SYSCONF_DIR="${WORKSPACE}/sysconfigdata-host"
if [ -d "$_SYSCONF_DIR" ]; then
    export PYTHONPATH="${PYSITE}:${_SYSCONF_DIR}:${BUILD_DEPS_SITE:-${WORKSPACE}/build-deps-site}"
else
    export PYTHONPATH="${PYSITE}:${BUILD_DEPS_SITE:-${WORKSPACE}/build-deps-site}"
fi

# ════════════════════════════════════════════════════════════
# [FIX BLDLIBRARY] Sed cứng placeholder trong MỌI _sysconfigdata
#                  nằm trong PYTHONPATH
# ════════════════════════════════════════════════════════════
for d in \
    "${WORKSPACE}/sysconfigdata-host" \
    "${HOST_PY_LIB}" \
    "${TARGET_STDLIB}"; do
    for f in "${d}"/_sysconfigdata__*.py; do
        [ -f "$f" ] || continue
        sed -i "s|\$(BLDLIBRARY)|-lpython${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
        sed -i "s|\$(LDLIBRARY)|libpython${PYTHON_MINOR}.so|g" "$f" 2>/dev/null || true
        sed -i "s|\$(LIBRARY)|python${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
    done
    find "${d}" -name "_sysconfigdata__*.pyc" -delete 2>/dev/null || true
    find "${d}/__pycache__" -name "_sysconfigdata__*" -delete 2>/dev/null || true
done

# Verify
VERIFY_OUT=$(
    PYTHONPATH="${PYSITE}:${_SYSCONF_DIR}" \
    "${HOST_PYTHON}" -c "import sysconfig; print(sysconfig.get_config_var('BLDLIBRARY'))" 2>/dev/null || echo "FAIL"
)
echo "  🔍 [verify] BLDLIBRARY = ${VERIFY_OUT}"
if printf '%s' "$VERIFY_OUT" | grep -qF '$(BLDLIBRARY)'; then
    echo "  ❌ Vẫn còn placeholder sau patch — abort"
    exit 1
fi
echo "  ✅ BLDLIBRARY OK"

# 6. site.cfg
if [ -d "$SRC_PATH" ] && [ ! -f "$SRC_PATH/site.cfg" ]; then
    cat > "$SRC_PATH/site.cfg" <<EOF
[openblas]
libraries = openblas
library_dirs = ${DEPS_INSTALL}/lib
include_dirs = ${DEPS_INSTALL}/include
runtime_library_dirs = ${DEPS_INSTALL}/lib
EOF
fi

# 7. Setup args
SETUP_ARGS=()
PLAT_NAME_ARG=""

case "$BACKEND" in
    *meson*)
        echo "  → Meson backend"
        case "$PKG_NAME" in
            numpy|scipy)
                echo "  → Aggressive patch BLDLIBRARY trong sysconfigdata"
                for f in \
                    "${HOST_PY_LIB}"/_sysconfigdata__*.py \
                    "${TARGET_STDLIB}"/_sysconfigdata__*.py \
                    "${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"/_sysconfigdata__*.py \
                    "${TARGET_ROOT}/lib/python${PYTHON_MINOR}"/_sysconfigdata__*.py \
                    "${_SYSCONF_DIR}"/_sysconfigdata__*.py; do
                    [ -f "$f" ] || continue
                    sed -i "s|\$(BLDLIBRARY)|-lpython${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
                    sed -i "s|\$(LDLIBRARY)|libpython${PYTHON_MINOR}.so|g" "$f" 2>/dev/null || true
                    sed -i "s|\$(LIBRARY)|python${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
                    echo "    ✅ patched: $f"
                done

                find "${HOST_PY_LIB}" "${TARGET_STDLIB}" \
                    -name "__pycache__" -type d \
                    -exec rm -rf {} + 2>/dev/null || true

                echo "  🔍 Verify BLDLIBRARY (grep file):"
                REMAIN=0
                for f in \
                    "${HOST_PY_LIB}"/_sysconfigdata__*.py \
                    "${TARGET_STDLIB}"/_sysconfigdata__*.py \
                    "${_SYSCONF_DIR}"/_sysconfigdata__*.py; do
                    [ -f "$f" ] || continue
                    if grep -qF '$(BLDLIBRARY)' "$f" 2>/dev/null; then
                        echo "    ❌ Còn placeholder: $f"
                        REMAIN=$((REMAIN+1))
                    fi
                done
                [ "$REMAIN" -gt 0 ] && { echo "  ❌ BLDLIBRARY patch failed"; exit 1; }
                echo "    ✅ Files OK"

                find "$SRC_PATH" -name "meson.build" -type f -print0 | \
                while IFS= read -r -d '' f; do
                    sed -i "s/'-O3'/'-O1'/g; s/'-O2'/'-O1'/g; \
                            s/optimization: 3/optimization: 1/g; \
                            s/optimization: 2/optimization: 1/g; \
                            s/optimization:'3'/optimization:'1'/g; \
                            s/optimization:'2'/optimization:'1'/g" "$f"
                done
                echo "  ✅ Patched $(find "$SRC_PATH" -name meson.build | wc -l) meson.build"

                if [ ! -f "${DEPS_INSTALL}/lib/pkgconfig/openblas.pc" ]; then
                    mkdir -p "${DEPS_INSTALL}/lib/pkgconfig"
                    cat > "${DEPS_INSTALL}/lib/pkgconfig/openblas.pc" <<PCEOF
prefix=${DEPS_INSTALL}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: OpenBLAS
Description: OpenBLAS
Version: 0.3.0
Libs: -L\${libdir} -lopenblas
Libs.private: -lm -ldl
Cflags: -I\${includedir}
PCEOF
                fi

                if ! PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig" \
                     /usr/bin/pkg-config --exists openblas; then
                    echo "  ❌ pkg-config không thấy openblas"
                    exit 1
                fi

                cat > "${TMP_BUILD}/native-tools.ini" <<EOF
[binaries]
python3 = '${HOST_PYTHON}'
python = '${HOST_PYTHON}'
python3.13 = '${HOST_PYTHON}'
cython = '${HOST_PY_PREFIX}/bin/cython'
cython3 = '${HOST_PY_PREFIX}/bin/cython3'
pkg-config = '/usr/bin/pkg-config'

[built-in options]
pkg_config_path = '${DEPS_INSTALL}/lib/pkgconfig:${DEPS_INSTALL}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig'
EOF

                cat > "${TMP_BUILD}/android-cross.ini" <<EOF
[binaries]
c = '${NDK_CC}'
cpp = '${NDK_CXX}'
ar = '${NDK_AR}'
strip = '${STRIP}'
ranlib = '${RANLIB}'
python3 = '${HOST_PYTHON}'
cython = '${HOST_PY_PREFIX}/bin/cython'
pkg-config = '/usr/bin/pkg-config'
exe_wrapper = '/bin/true'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
longdouble_format = 'IEEE_QUAD_LE'
needs_exe_wrapper = true

[built-in options]
pkg_config_path = '${DEPS_INSTALL}/lib/pkgconfig:${DEPS_INSTALL}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig'
c_args   = ['-O1', '-fno-vectorize', '-fno-slp-vectorize']
cpp_args = ['-O1', '-fno-vectorize', '-fno-slp-vectorize']
EOF
                SETUP_ARGS=(
                    "-Csetup-args=--cross-file=${TMP_BUILD}/android-cross.ini"
                    "-Csetup-args=--native-file=${TMP_BUILD}/native-tools.ini"
                    "-Csetup-args=-Dblas=openblas"
                    "-Csetup-args=-Dlapack=openblas"
                    "-Csetup-args=-Dallow-noblas=false"
                    "-Csetup-args=-Dbuildtype=plain"
                )
                ;;
            *)
                SETUP_ARGS=(
                    "-Csetup-args=-Dblas=openblas"
                    "-Csetup-args=-Dlapack=openblas"
                    "-Csetup-args=-Dallow-noblas=false"
                    "-Csetup-args=-Dbuildtype=release"
                )
                ;;
        esac
        ;;
    *maturin*)
        echo "  → Maturin backend"
        export PYO3_PYTHON="${HOST_PYTHON}"
        export PYO3_CROSS=1
        export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
        export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
        export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
        export PYO3_CONFIG_FILE="${PYO3_CONFIG}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_CC}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${TARGET_ROOT}/lib"
        unset RUSTFLAGS

        # ═══ [ABI3] Bật PyO3 abi3 + ép không link libpython ═══
        if [ "$USE_ABI3" -eq 1 ]; then
            export PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1
            SETUP_ARGS+=("--config-settings=--features=abi3")
            echo "  🔗 maturin: --features=abi3"

            export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="\
-C link-arg=-Wl,--as-needed \
-C link-arg=-Wl,--allow-shlib-undefined \
-C link-arg=-L${TARGET_ROOT}/lib"
        else
            export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="\
-C link-arg=-L${TARGET_ROOT}/lib \
-C link-arg=-lpython${PYTHON_MINOR}"
        fi
        ;;
    *)
        echo "  → Setuptools backend"
        PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}"
        if [ "$USE_ABI3" -eq 1 ]; then
            SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=${ABI3_TARGET}")
            echo "  🔗 setuptools: --py-limited-api=${ABI3_TARGET}"
        fi
        ;;
esac

# 8. Patch đặc biệt
case "$PKG_NAME" in
    Pillow|pillow|PIL)
        echo "  → Patch Pillow"
        export FREETYPE_ROOT="${DEPS_INSTALL}"
        export ZLIB_ROOT="${DEPS_INSTALL}"
        export JPEG_ROOT="${DEPS_INSTALL}"
        export TIFF_ROOT="${DEPS_INSTALL}"
        export LCMS_ROOT="${DEPS_INSTALL}"
        export OPENJPEG_ROOT="${DEPS_INSTALL}"
        export LIBIMAGEQUANT_ROOT="${DEPS_INSTALL}"
        export WEBP_ROOT="${DEPS_INSTALL}"
        export XCB_ROOT="/nonexistent/skip"

        cd "$SRC_PATH"
        cp setup.py setup.py.bak 2>/dev/null || true

        cat > /tmp/patch_pillow.py <<'PYEOF'
import re
with open("setup.py", "r") as f:
    c = f.read()
q1, q2 = chr(34), chr(39)
skip = "/nonexistent/skip"
for path in ["/usr/include", "/usr/local/include", "/usr/lib",
             "/usr/local/lib", "/usr/lib/x86_64-linux-gnu", "/usr/lib64",
             "/usr/include/freetype2", "/usr/include/libpng16",
             "/opt/host-python/lib", "/opt/host-python/include",
             "/opt/host-python/bin"]:
    c = c.replace(q1+path+q1, q1+skip+q1)
    c = c.replace(q2+path+q2, q2+skip+q2)
c = re.sub(
    r"_add_directory\([^,]+,\s*[\x27\x22]/(usr|opt/host)[^\x27\x22]*[\x27\x22]\)",
    "pass", c)
filter_code = '''
import os as _os
_ALLOWED_PREFIXES = (
    "/work/python-android", "/work/deps-install",
    "/tmp/p4a-build", "/opt/ndk",
)
_BAD_PREFIXES = (
    "/usr/include", "/usr/local/include", "/usr/lib",
    "/usr/local/lib", "/usr/lib64", "/usr/lib/x86_64-linux-gnu",
    "/opt/host-python",
)
def _p4a_bad(p):
    p = str(p)
    for a in _ALLOWED_PREFIXES:
        if p.startswith(a): return False
    for b in _BAD_PREFIXES:
        if p.startswith(b): return True
    return False
def _p4a_clean(lst):
    if not lst: return lst
    out = []
    for d in lst:
        if isinstance(d, str) and ("libpython" in d or "pkgconfig" in d):
            out.append(d); continue
        if _p4a_bad(d):
            print("[p4a-pillow] drop:", d); continue
        out.append(d)
    return out
try:
    from setuptools.command.build_ext import build_ext as _be_cls
    _orig_fo = _be_cls.finalize_options
    def _new_fo(self):
        _orig_fo(self)
        self.include_dirs = _p4a_clean(self.include_dirs)
        self.library_dirs = _p4a_clean(self.library_dirs)
        if getattr(self, "rpath", None):
            self.rpath = _p4a_clean(self.rpath)
        deps = _os.environ.get("DEPS_INSTALL", "")
        if deps:
            for d in (deps + "/include", deps + "/include/freetype2",
                      deps + "/include/libpng16"):
                if _os.path.isdir(d) and d not in self.include_dirs:
                    self.include_dirs.insert(0, d)
            for d in (deps + "/lib",):
                if _os.path.isdir(d) and d not in self.library_dirs:
                    self.library_dirs.insert(0, d)
    _be_cls.finalize_options = _new_fo
except Exception as e:
    print("[p4a-pillow] WARN finalize_options:", e)
try:
    _orig_be = _be_cls.build_extension
    def _new_be(self, ext):
        ext.include_dirs = _p4a_clean(ext.include_dirs)
        ext.library_dirs = _p4a_clean(ext.library_dirs)
        return _orig_be(self, ext)
    _be_cls.build_extension = _new_be
except Exception as e:
    print("[p4a-pillow] WARN build_extension:", e)
'''
matches = list(re.finditer(r'^(\s*)setup\(', c, re.MULTILINE))
if matches:
    m = matches[-1]
    idx = m.start()
    indent = m.group(1)
    indented = "\n".join((indent+l) if l.strip() else l
                         for l in filter_code.split("\n"))
    c = c[:idx] + indented + c[idx:]
with open("setup.py", "w") as f:
    f.write(c)
print("[p4a-pillow] setup.py patched")
PYEOF
        "${HOST_PYTHON}" /tmp/patch_pillow.py
        ;;

    cffi)
        if [ "$USE_ABI3" -eq 1 ]; then
            case "$ABI3_TARGET" in
                cp37)  ABI3_HEX="0x03070000" ;;
                cp38)  ABI3_HEX="0x03080000" ;;
                cp39)  ABI3_HEX="0x03090000" ;;
                cp310) ABI3_HEX="0x030A0000" ;;
                cp311) ABI3_HEX="0x030B0000" ;;
                cp312) ABI3_HEX="0x030C0000" ;;
                *)     ABI3_HEX="0x03080000" ;;
            esac
            export CFFI_PY_LIMITED_API="$ABI3_HEX"
            SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=${ABI3_TARGET}")
            echo "  🔗 cffi: abi3 ${ABI3_TARGET} (Py_LIMITED_API=${ABI3_HEX})"
        else
            export CFFI_PY_LIMITED_API="0x030D0000"
            SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=cp313")
        fi
        ;;

    zstandard)
        echo "  → zstandard: cffi đã dọn"
        ;;

    cryptography)
        echo "  → cryptography: CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=1"
        export CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=1
        ;;

    uvloop)
        echo "  → Patch uvloop setup.py: --host cho libuv configure"
        UV_SETUP="${SRC_PATH}/setup.py"
        if [ -f "$UV_SETUP" ]; then
            cp "$UV_SETUP" "${UV_SETUP}.bak"
            UV_SETUP="$UV_SETUP" TARGET_HOST="aarch64-linux-android" \
            "${HOST_PYTHON}" - <<'PYEOF'
import os
p = os.environ["UV_SETUP"]
host = os.environ.get("TARGET_HOST", "aarch64-linux-android")
src = open(p).read()
orig = src
src = src.replace(
    "['./configure']",
    "['./configure', '--host=" + host + "', '--build=x86_64-pc-linux-gnu',"
    " '--disable-shared', '--enable-static']"
)
src = src.replace(
    '[\"./configure\"]',
    '[\"./configure\", \"--host=' + host + '\",'
    ' \"--build=x86_64-pc-linux-gnu\",'
    ' \"--disable-shared\", \"--enable-static\"]'
)
if src != orig:
    open(p, "w").write(src)
    print(f"[uvloop-patch] patched: {p}")
else:
    print(f"[uvloop-patch] no change in {p}")
PYEOF
        fi
        export ac_cv_host="aarch64-linux-android"
        export ac_cv_build="x86_64-pc-linux-gnu"
        export ac_cv_target="aarch64-linux-android"
        export cross_compiling="yes"
        # ═══ [FIX] HOSTCC/HOSTCXX phải là compiler x86_64 ═══
        export HOSTCC="/usr/bin/gcc"
        export HOSTCXX="/usr/bin/g++"
        export CC_FOR_BUILD="/usr/bin/gcc"
        export CXX_FOR_BUILD="/usr/bin/g++"
        export AR_FOR_BUILD="/usr/bin/ar"
        export RANLIB_FOR_BUILD="/usr/bin/ranlib"
        ;;
esac

# 9. Build
cd "$SRC_PATH"

BUILD_CMD=("${HOST_PYTHON}" -m pip wheel . --no-deps --no-build-isolation --wheel-dir "${WHEELS_OUT}")
[ -n "$PLAT_NAME_ARG" ] && BUILD_CMD+=("$PLAT_NAME_ARG")
[ "${#SETUP_ARGS[@]}" -gt 0 ] && BUILD_CMD+=("${SETUP_ARGS[@]}")

if env \
    "CC_aarch64-linux-android=${NDK_CC}" \
    "CXX_aarch64-linux-android=${NDK_CXX}" \
    "AR_aarch64-linux-android=${NDK_AR}" \
    "CFLAGS_aarch64-linux-android=${CFLAGS_aarch64_linux_android}" \
    "LDFLAGS_aarch64-linux-android=${LDFLAGS_aarch64_linux_android}" \
    "${BUILD_CMD[@]}" > "$LOG" 2>&1; then
    tail -5 "$LOG"
    echo "✅ $PKG_NAME built"
else
    RC=$?
    echo "--- pip log (tail 60) ---"
    tail -60 "$LOG"
    exit $RC
fi

# ════════════════════════════════════════════════════════════
# 10. Post-build: strip libpython khỏi abi3, add cho native
# ════════════════════════════════════════════════════════════
repack_wheel_record() {
    local whl="$1" work="$2"
    WHL="$whl" WORK_TMP="$work" "${HOST_PYTHON}" - <<'PYEOF'
import base64, hashlib, csv, os, zipfile, shutil
whl = os.environ["WHL"]
tmp = os.environ["WORK_TMP"]
record_path = None
for root, _, files in os.walk(tmp):
    if root.endswith(".dist-info") and "RECORD" in files:
        record_path = os.path.join(root, "RECORD")
        break
if record_path:
    with open(record_path, "r", newline="") as f:
        rows = list(csv.reader(f))
    for r in rows:
        if len(r) >= 3 and r[0] and not r[0].endswith("RECORD"):
            full = os.path.join(tmp, r[0])
            if os.path.isfile(full):
                with open(full, "rb") as fh:
                    data = fh.read()
                d = base64.urlsafe_b64encode(
                    hashlib.sha256(data).digest()
                ).rstrip(b"=").decode()
                r[1] = f"sha256={d}"
                r[2] = str(len(data))
    with open(record_path, "w", newline="") as f:
        csv.writer(f).writerows(rows)
out = whl + ".tmp"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, _, files in os.walk(tmp):
        for fn in files:
            full = os.path.join(root, fn)
            zf.write(full, os.path.relpath(full, tmp))
shutil.move(out, whl)
print(f"[repack] {whl}")
PYEOF
}

strip_libpython_from_wheel() {
    local whl="$1"
    local work
    work="$(mktemp -d)"
    local changed=0
    unzip -o -q "$whl" -d "$work"
    while IFS= read -r so; do
        [ -f "$so" ] || continue
        local needed
        needed=$(${READELF} -d "$so" 2>/dev/null \
                 | grep -E 'NEEDED.*libpython3\.[0-9]+\.so' \
                 | sed -E 's/.*\[([^]]+)\].*/\1/' || true)
        [ -z "$needed" ] && continue
        for lib in $needed; do
            echo "    🧹 strip NEEDED $lib khỏi $(basename "$so")"
            patchelf --remove-needed "$lib" "$so" || true
            changed=1
        done
    done < <(find "$work" -name "*.so")
    if [ "$changed" -eq 1 ]; then
        repack_wheel_record "$whl" "$work"
    fi
    rm -rf "$work"
}

add_libpython_to_wheel() {
    local whl="$1"
    local work
    work="$(mktemp -d)"
    local changed=0
    unzip -o -q "$whl" -d "$work"
    while IFS= read -r so; do
        [ -f "$so" ] || continue
        if ${READELF} -d "$so" 2>/dev/null | grep -q "libpython${PYTHON_MINOR}.so"; then
            continue
        fi
        case "$so" in
            *.cpython-*.so|*abi3*.so|*_rust*.so)
                patchelf --add-needed "libpython${PYTHON_MINOR}.so" "$so" || true
                changed=1
                ;;
        esac
        if ! ${READELF} -d "$so" 2>/dev/null | grep -qE "RPATH|RUNPATH"; then
            patchelf --force-rpath --set-rpath '$ORIGIN/../../../../..' "$so" || true
            changed=1
        fi
    done < <(find "$work" -name "*.so")
    if [ "$changed" -eq 1 ]; then
        repack_wheel_record "$whl" "$work"
    fi
    rm -rf "$work"
}

shopt -s nullglob
for whl in "${WHEELS_OUT}"/*.whl; do
    [ -f "$whl" ] || continue
    base=$(basename "$whl")
    [[ "$base" == *"none-any"* ]] && continue

    if [[ "$base" == *"-abi3-"* ]]; then
        echo "  🔧 [abi3] Strip libpython khỏi $base"
        strip_libpython_from_wheel "$whl"
    else
        echo "  🔧 [native] Add libpython cho $base"
        add_libpython_to_wheel "$whl"
    fi
done
shopt -u nullglob

exit 0