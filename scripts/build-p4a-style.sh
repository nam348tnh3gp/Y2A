#!/bin/bash
# build-p4a-style.sh — native build cho PYTHON_MINOR, hỗ trợ p4a recipes
# Fixes: numpy $(BLDLIBRARY) placeholder, uvloop libuv cross, orjson skip, cryptography OSSL
set -eo pipefail

PKG_SPEC="${1:-}"
[ -z "$PKG_SPEC" ] && { echo "❌ Missing pkg"; exit 1; }
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

echo "  📦 Build native cho Python ${PYTHON_MINOR} (không abi3)"

TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
PYSITE="${TMP_BUILD}/pysite"
LOG="/tmp/p4a-${PKG_NAME}.log"

rm -rf "$TMP_BUILD"
mkdir -p "$SRC_DIR" "${TMP_BUILD}/bin" "$PYSITE"

echo "  Building: $PKG_SPEC"
echo "  PKG_NAME: $PKG_NAME"

# ════════════════════════════════════════════════════════════
# SKIP packages (intentional — exit 0 + marker)
# ════════════════════════════════════════════════════════════
case "$PKG_NAME" in
    orjson)
        echo "  ⏭️  orjson: skip (x86-only SIMD code) — SKIP_INTENTIONAL"
        exit 0
        ;;
esac

# ════════════════════════════════════════════════════════════
# sanitize_sysconfigdata — patch TRIỆT ĐỂ mọi placeholder
# ════════════════════════════════════════════════════════════
sanitize_sysconfigdata() {
    local PY="$1"
    local TARGETS=(
        "${HOST_PY_LIB}"
        "${TARGET_STDLIB}"
        "${WORKSPACE}/sysconfigdata-host"
        "${HOST_PY_PREFIX}/lib/python${PY}"
        "${TARGET_ROOT}/lib/python${PY}"
    )
    local N=0
    for d in "${TARGETS[@]}"; do
        [ -d "$d" ] || continue
        for f in "${d}"/_sysconfigdata__*.py; do
            [ -f "$f" ] || continue
            sed -i \
                -e "s|'\$(BLDLIBRARY)'|'-lpython${PY}'|g" \
                -e "s|\"\$(BLDLIBRARY)\"|\"-lpython${PY}\"|g" \
                -e "s|'\$(LDLIBRARY)'|'libpython${PY}.so'|g" \
                -e "s|\"\$(LDLIBRARY)\"|\"libpython${PY}.so\"|g" \
                -e "s|'\$(LIBRARY)'|'python${PY}'|g" \
                -e "s|\"\$(LIBRARY)\"|\"python${PY}\"|g" \
                "$f" 2>/dev/null || true
            rm -f "${f}c" 2>/dev/null || true
            N=$((N+1))
        done
        rm -rf "${d}/__pycache__" 2>/dev/null || true
    done
    echo "    sanitize: ${N} file(s)"
}

echo "🔧 Sanitize sysconfigdata TRƯỚC khi import..."
sanitize_sysconfigdata "${PYTHON_MINOR}"

# Symlink python tools
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python3"
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python"
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python${PYTHON_MINOR}"
[ -f "${HOST_PY_PREFIX}/bin/cython" ] && ln -sf "${HOST_PY_PREFIX}/bin/cython" "${TMP_BUILD}/bin/cython"
[ -f "${HOST_PY_PREFIX}/bin/cython3" ] && ln -sf "${HOST_PY_PREFIX}/bin/cython3" "${TMP_BUILD}/bin/cython3"

# 1. Download source
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
export PYTHONNOUSERSITE=1

# Force đúng sysconfigdata
_SC_FILE=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
if [ -n "$_SC_FILE" ]; then
    export _PYTHON_SYSCONFIGDATA_NAME="$(basename "$_SC_FILE" .py)"
    echo "  🔧 _PYTHON_SYSCONFIGDATA_NAME=${_PYTHON_SYSCONFIGDATA_NAME}"
    cp -f "$_SC_FILE" "${HOST_PY_LIB}/${_PYTHON_SYSCONFIGDATA_NAME}.py" 2>/dev/null || true
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

# autoconf cross env
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
abi3=false
lib_name=python${PYTHON_MINOR}
lib_dir=${TARGET_ROOT}/lib
executable=${TARGET_ROOT}/bin/python${PYTHON_MINOR}
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
EOF
export PYO3_CONFIG_FILE="$PYO3_CONFIG"
echo "  🔧 PYO3_CONFIG: abi3=false (native)"

export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include/python${PYTHON_MINOR}"

# ── GHI ĐÈ host sitecustomize ──
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

cp "${HOST_PY_LIB}/sitecustomize.py" "${PYSITE}/sitecustomize.py"

_SYSCONF_DIR="${WORKSPACE}/sysconfigdata-host"
if [ -d "$_SYSCONF_DIR" ]; then
    export PYTHONPATH="${PYSITE}:${_SYSCONF_DIR}:${BUILD_DEPS_SITE:-${WORKSPACE}/build-deps-site}"
else
    export PYTHONPATH="${PYSITE}:${BUILD_DEPS_SITE:-${WORKSPACE}/build-deps-site}"
fi

# Sed placeholder BLDLIBRARY (lần 2, sau khi sitecustomize sẵn sàng)
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

# ════════════════════════════════════════════════════════════
# Verify CỨNG không còn placeholder
# ════════════════════════════════════════════════════════════
echo "🔍 Verify không còn \$(BLDLIBRARY)..."
REMAIN=0
for d in "${HOST_PY_LIB}" "${TARGET_STDLIB}" \
         "${WORKSPACE}/sysconfigdata-host" \
         "${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}" \
         "${TARGET_ROOT}/lib/python${PYTHON_MINOR}"; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do
        if grep -qF '$(BLDLIBRARY)' "$f" 2>/dev/null; then
            echo "  ❌ Còn placeholder: $f"
            REMAIN=$((REMAIN+1))
        fi
    done < <(find "$d" -name "_sysconfigdata__*.py" 2>/dev/null)
done
if [ "$REMAIN" -gt 0 ]; then
    echo "  ❌ $REMAIN file còn placeholder — ABORT"
    exit 1
fi
echo "  ✅ Không còn placeholder trong file"

echo "🔍 Verify bằng Python (giống meson-python gọi):"
BLD_RESULT=$("${HOST_PYTHON}" -c "
import sysconfig, os
os.environ.setdefault('_PYTHON_SYSCONFIGDATA_NAME', '${_PYTHON_SYSCONFIGDATA_NAME:-}')
v = sysconfig.get_config_var('BLDLIBRARY')
print(v if v is not None else 'NONE')
" 2>&1 || echo "FAIL")
echo "    get_config_var('BLDLIBRARY') = ${BLD_RESULT}"
if printf '%s' "$BLD_RESULT" | grep -qF '$(BLDLIBRARY)'; then
    echo "    ❌ Python vẫn trả về placeholder — ABORT"
    exit 1
fi
if [ "$BLD_RESULT" = "NONE" ] || [ "$BLD_RESULT" = "FAIL" ]; then
    echo "    ❌ Python không đọc được BLDLIBRARY — ABORT"
    exit 1
fi
echo "    ✅ OK"

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

# 7. Setup args — base theo backend
SETUP_ARGS=()
PLAT_NAME_ARG=""

case "$BACKEND" in
    *meson*)
        echo "  → Meson backend"
        case "$PKG_NAME" in
            numpy|scipy)
                echo "  → Aggressive patch BLDLIBRARY"

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
                done

                find "${HOST_PY_LIB}" "${TARGET_STDLIB}" \
                    -name "__pycache__" -type d \
                    -exec rm -rf {} + 2>/dev/null || true

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

                find "$SRC_PATH" -name "meson.build" -type f -print0 | \
                while IFS= read -r -d '' f; do
                    sed -i "s/'-O3'/'-O1'/g; s/'-O2'/'-O1'/g; \
                            s/optimization: 3/optimization: 1/g; \
                            s/optimization: 2/optimization: 1/g; \
                            s/optimization:'3'/optimization:'1'/g; \
                            s/optimization:'2'/optimization:'1'/g" "$f"
                done

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
python${PYTHON_MINOR} = '${HOST_PYTHON}'
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
        echo "  → Maturin backend (native)"
        export PYO3_PYTHON="${HOST_PYTHON}"
        export PYO3_CROSS=1
        export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
        export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
        export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
        export PYO3_CONFIG_FILE="${PYO3_CONFIG}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_CC}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="\
-C link-arg=-L${TARGET_ROOT}/lib \
-C link-arg=-lpython${PYTHON_MINOR}"
        unset RUSTFLAGS
        ;;
    *)
        echo "  → Setuptools backend (native)"
        PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}"
        ;;
esac

# ════════════════════════════════════════════════════════════
# 8a. p4a-style recipe (nếu có)
# ════════════════════════════════════════════════════════════
RECIPE_FILE="${WORKSPACE}/recipes/${PKG_NAME}.sh"
if [ -f "$RECIPE_FILE" ]; then
    echo "  📖 [p4a-recipe] source $(basename "$RECIPE_FILE")"
    # shellcheck disable=SC1090
    source "$RECIPE_FILE"

    if declare -F recipe_env >/dev/null 2>&1; then
        recipe_env
    fi

    if declare -F recipe_setup_args >/dev/null 2>&1; then
        while IFS= read -r _arg; do
            [ -n "$_arg" ] && SETUP_ARGS+=("$_arg")
        done < <(recipe_setup_args || true)
    fi

    if declare -F recipe_patch >/dev/null 2>&1; then
        recipe_patch "$SRC_PATH" || echo "  ⚠️  recipe_patch non-zero"
    fi
    echo "  ✅ [p4a-recipe] applied"
fi

# ════════════════════════════════════════════════════════════
# 8b. Patch đặc biệt
# ════════════════════════════════════════════════════════════
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
        if p.startswith(a): return False    for b in _BAD_PREFIXES:
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
        echo "  → cffi: native (không abi3)"
        unset CFFI_PY_LIMITED_API 2>/dev/null || true
        ;;

    zstandard)
        echo "  → zstandard: cffi đã dọn"
        ;;

    cryptography)
        echo "  → cryptography: OPENSSL_DIR + provider flags"
        export OPENSSL_DIR="${DEPS_INSTALL}"
        export OPENSSL_LIB_DIR="${DEPS_INSTALL}/lib"
        export OPENSSL_INCLUDE_DIR="${DEPS_INSTALL}/include"
        # KHÔNG disable legacy → giữ OSSL_PROVIDER_unload
        export CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=0
        export OPENSSL_NO_MODULE=1
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
# 10. Post-build: add libpython (native path)
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
            *.cpython-*.so|*_rust*.so)
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

    echo "  🔧 [native] Add libpython cho $base"
    add_libpython_to_wheel "$whl"
done
shopt -u nullglob

# ════════════════════════════════════════════════════════════
# 11. Verify đặc biệt cho cryptography
# ════════════════════════════════════════════════════════════
case "$PKG_NAME" in
    cryptography)
        echo "  🔍 [verify/cryptography] check OSSL_PROVIDER symbols..."
        shopt -s nullglob
        for whl in "${WHEELS_OUT}"/cryptography-*.whl; do
            [ -f "$whl" ] || continue
            tmp=$(mktemp -d)
            unzip -q -o "$whl" -d "$tmp"

            while IFS= read -r so; do
                [ -f "$so" ] || continue
                echo "    → $(basename "$so")"

                if ${READELF} -d "$so" 2>/dev/null | grep -qE 'NEEDED.*libcrypto\.so'; then
                    echo "      ✅ NEEDED libcrypto.so"
                else
                    echo "      ⚠️  không NEEDED libcrypto.so"
                fi

                if ${NDK_TOOLCHAIN}/bin/llvm-nm -D "$so" 2>/dev/null \
                     | grep -q 'U OSSL_PROVIDER_unload'; then
                    echo "      ⚠️  U OSSL_PROVIDER_unload (runtime cần libcrypto đủ)"
                fi

                rpath=$(${READELF} -d "$so" 2>/dev/null | grep -E 'RPATH|RUNPATH' | head -1 || true)
                [ -n "$rpath" ] && echo "      rpath: $rpath"
            done < <(find "$tmp" -name "_rust*.so" -o -name "*.abi3.so" -o -name "_rust*.cpython*.so")

            rm -rf "$tmp"
        done
        shopt -u nullglob
        ;;
esac

exit 0