#!/bin/bash
# build-p4a-style.sh
set -eo pipefail

PKG_SPEC="${1:-}"
[ -z "$PKG_SPEC" ] && { echo "❌ Missing pkg"; exit 1; }
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
PYSITE="${TMP_BUILD}/pysite"
LOG="/tmp/p4a-${PKG_NAME}.log"

rm -rf "$TMP_BUILD"
mkdir -p "$SRC_DIR" "${TMP_BUILD}/bin" "$PYSITE"

echo "  Building: $PKG_SPEC"
echo "  PKG_NAME: $PKG_NAME"

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
    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
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

# ════════════════════════════════════════════════════════════
# [FIX BLAS detection] pkg-config cho NumPy meson build
# ════════════════════════════════════════════════════════════
export PKG_CONFIG="${PKG_CONFIG:-/usr/bin/pkg-config}"
export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig:${DEPS_INSTALL}/share/pkgconfig:/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:/usr/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
unset PKG_CONFIG_LIBDIR
unset PKG_CONFIG_SYSROOT_DIR

# ════════════════════════════════════════════════════════════
# [NDK r27] NumPy ICE workaround
# ════════════════════════════════════════════════════════════
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

# sitecustomize cho PYSITE
cat > "${PYSITE}/sitecustomize.py" <<SITEEOF
import sysconfig
_patches = {
    'LIBPL': "${TARGET_ROOT}/lib",
    'LIBDIR': "${TARGET_ROOT}/lib",
    'LIBDEST': "${TARGET_ROOT}/lib/python${PYTHON_MINOR}",
    'INCLUDEPY': "${TARGET_ROOT}/include/python${PYTHON_MINOR}",
    'CONFINCLUDEPY': "${TARGET_ROOT}/include/python${PYTHON_MINOR}",
    'LIBRARY': "python${PYTHON_MINOR}",
    'LDLIBRARY': "libpython${PYTHON_MINOR}.so",
    'BLDLIBRARY': "-lpython${PYTHON_MINOR}",
}
_orig = sysconfig.get_config_var
def _gcv(name):
    return _patches.get(name, _orig(name))
sysconfig.get_config_var = _gcv
SITEEOF

# ════════════════════════════════════════════════════════════
# PYTHONPATH = PYSITE + BUILD_DEPS_SITE
# ════════════════════════════════════════════════════════════
export PYTHONPATH="${PYSITE}:${BUILD_DEPS_SITE:-${WORKSPACE}/build-deps-site}"

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
                # ════════════════════════════════════════════════════════════
                # [FIX NumPy BLDLIBRARY] Aggressive patch
                #
                # Vấn đề: _sysconfigdata chứa 'BLDLIBRARY': '$(BLDLIBRARY)'
                # (placeholder Makefile). NumPy meson đọc trực tiếp →
                # nhận literal → clang++ "no such file: $(BLDLIBRARY)".
                #
                # Fix: thay THẲNG mọi occurrence của placeholder bằng
                # giá trị thật, KHÔNG quan tâm quoting/structure. Patch
                # mọi file sysconfigdata có thể có + xoá __pycache__.
                # ════════════════════════════════════════════════════════════
                echo "  → Aggressive patch BLDLIBRARY trong sysconfigdata"
                for f in \
                    "${HOST_PY_LIB}"/_sysconfigdata__*.py \
                    "${TARGET_STDLIB}"/_sysconfigdata__*.py \
                    "${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"/_sysconfigdata__*.py \
                    "${TARGET_ROOT}/lib/python${PYTHON_MINOR}"/_sysconfigdata__*.py; do
                    [ -f "$f" ] || continue
                    sed -i "s|\$(BLDLIBRARY)|-lpython${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
                    sed -i "s|\$(LDLIBRARY)|libpython${PYTHON_MINOR}.so|g" "$f" 2>/dev/null || true
                    sed -i "s|\$(LIBRARY)|python${PYTHON_MINOR}|g" "$f" 2>/dev/null || true
                    echo "    ✅ patched: $f"
                done

                # Xoá __pycache__ để Python KHÔNG load .pyc cũ
                find "${HOST_PY_LIB}" "${TARGET_STDLIB}" \
                    -name "__pycache__" -type d \
                    -exec rm -rf {} + 2>/dev/null || true
                rm -f "${HOST_PY_LIB}"/__pycache__/_sysconfigdata*.pyc 2>/dev/null || true
                rm -f "${TARGET_STDLIB}"/__pycache__/_sysconfigdata*.pyc 2>/dev/null || true

                # Verify bằng cách đọc trực tiếp từ module
                echo "  🔍 Verify BLDLIBRARY qua Python:"
                PYTHONPATH="${PYSITE}" "${HOST_PYTHON}" -c "
import os, importlib
os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'
import sys as _s
for m in list(_s.modules):
    if m.startswith('_sysconfigdata'):
        del _s.modules[m]
mod = importlib.import_module('${SYSCONF_NAME}')
v = mod.build_time_vars.get('BLDLIBRARY', 'MISSING')
print(f'    BLDLIBRARY = {v!r}')
if '\$(' in str(v):
    raise SystemExit('BLDLIBRARY vẫn còn placeholder!')
print('    ✅ BLDLIBRARY OK')
" || { echo "  ❌ BLDLIBRARY patch failed"; exit 1; }

                # Patch meson.build optimization
                echo "  → Patch NumPy/SciPy meson.build: -O3/-O2 → -O1"
                find "$SRC_PATH" -name "meson.build" -type f -print0 | \
                while IFS= read -r -d '' f; do
                    sed -i "s/'-O3'/'-O1'/g; s/'-O2'/'-O1'/g; \
                            s/optimization: 3/optimization: 1/g; \
                            s/optimization: 2/optimization: 1/g; \
                            s/optimization:'3'/optimization:'1'/g; \
                            s/optimization:'2'/optimization:'1'/g" "$f"
                done
                echo "  ✅ Patched $(find "$SRC_PATH" -name meson.build | wc -l) meson.build files"

                # openblas.pc fallback
                if [ ! -f "${DEPS_INSTALL}/lib/pkgconfig/openblas.pc" ]; then
                    echo "  ⚠️  openblas.pc missing — generating fallback"
                    mkdir -p "${DEPS_INSTALL}/lib/pkgconfig"
                    cat > "${DEPS_INSTALL}/lib/pkgconfig/openblas.pc" <<PCEOF
prefix=${DEPS_INSTALL}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: OpenBLAS
Description: OpenBLAS is an optimized BLAS library
Version: 0.3.0
Libs: -L\${libdir} -lopenblas
Libs.private: -lm -ldl
Cflags: -I\${includedir}
PCEOF
                fi

                if ! PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig" \
                     /usr/bin/pkg-config --exists openblas; then
                    echo "  ❌ pkg-config KHÔNG tìm thấy openblas"
                    exit 1
                fi
                echo "  ✅ pkg-config OK: $(PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig" /usr/bin/pkg-config --modversion openblas)"

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
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${TARGET_ROOT}/lib -C link-arg=-lpython${PYTHON_MINOR}"
        unset RUSTFLAGS
        ;;
    *)
        echo "  → Setuptools backend"
        PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}"
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

        MISSING_PILLOW=""
        for lib in libfreetype libjpeg libpng libz; do
            if [ ! -f "${DEPS_INSTALL}/lib/${lib}.a" ] && \
               [ ! -f "${DEPS_INSTALL}/lib/${lib}.so" ]; then
                MISSING_PILLOW="$MISSING_PILLOW ${lib}"
            fi
        done
        if [ -n "$MISSING_PILLOW" ]; then
            echo "  ⚠️  Missing cross-compiled:${MISSING_PILLOW}"
            case "$MISSING_PILLOW" in
                *libfreetype*) export FREETYPE_ROOT="/nonexistent/skip" ;;
            esac
            case "$MISSING_PILLOW" in
                *libjpeg*) export JPEG_ROOT="/nonexistent/skip" ;;
            esac
            case "$MISSING_PILLOW" in
                *libpng*) export ZLIB_ROOT="/nonexistent/skip" ;;
            esac
        else
            echo "  ✅ cross-compiled libs OK (freetype/jpeg/png/z)"
        fi

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
    "/work/python-android",
    "/work/deps-install",
    "/tmp/p4a-build",
    "/opt/ndk",
)
_BAD_PREFIXES = (
    "/usr/include",
    "/usr/local/include",
    "/usr/lib",
    "/usr/local/lib",
    "/usr/lib64",
    "/usr/lib/x86_64-linux-gnu",
    "/opt/host-python",
)

def _p4a_bad(p):
    p = str(p)
    for a in _ALLOWED_PREFIXES:
        if p.startswith(a):
            return False
    for b in _BAD_PREFIXES:
        if p.startswith(b):
            return True
    return False

def _p4a_clean(lst):
    if not lst:
        return lst
    out = []
    for d in lst:
        if isinstance(d, str) and ("libpython" in d or "pkgconfig" in d):
            out.append(d)
            continue
        if _p4a_bad(d):
            print("[p4a-pillow] drop:", d)
            continue
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
    print("[p4a-pillow] WARN patch finalize_options failed:", e)

try:
    _orig_be = _be_cls.build_extension
    def _new_be(self, ext):
        ext.include_dirs = _p4a_clean(ext.include_dirs)
        ext.library_dirs = _p4a_clean(ext.library_dirs)
        return _orig_be(self, ext)
    _be_cls.build_extension = _new_be
except Exception as e:
    print("[p4a-pillow] WARN patch build_extension failed:", e)
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
        export CFFI_PY_LIMITED_API="0x030D0000"
        SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=cp313")
        ;;

    zstandard)
        echo "  → zstandard: cffi đã dọn"
        ;;

    cryptography)
        echo "  → cryptography: CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=1"
        export CRYPTOGRAPHY_BUILD_OPENSSL_NO_LEGACY=1
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

# 10. Patch cryptography
case "$PKG_NAME" in
    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
        pkg_under=$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        pkg_lower=$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]')
        WHL=$(ls -t "${WHEELS_OUT}"/${pkg_under}-*.whl \
                    "${WHEELS_OUT}"/${pkg_lower}-*.whl \
                    "${WHEELS_OUT}"/${PKG_NAME}-*.whl 2>/dev/null | head -1 || true)
        [ -z "$WHL" ] && exit 0
        WHL=$(realpath "$WHL")
        WORK="/tmp/patch-${PKG_NAME}"
        rm -rf "$WORK" && mkdir -p "$WORK"
        cd "$WORK"
        unzip -o -q "$WHL"
        RUST_SO=$(find . -name "_rust*.so" -o -name "*.abi3.so" | head -1)
        [ -z "$RUST_SO" ] && exit 0
        PATCHED=0
        if ! ${READELF} -d "$RUST_SO" | grep -q "libpython${PYTHON_MINOR}.so"; then
            patchelf --add-needed "libpython${PYTHON_MINOR}.so" "$RUST_SO"
            PATCHED=1
        fi
        if ! ${READELF} -d "$RUST_SO" | grep -qE "RPATH|RUNPATH"; then
            patchelf --force-rpath --set-rpath '$ORIGIN/../../../../..' "$RUST_SO"
            PATCHED=1
        fi
        if [ "$PATCHED" -eq 1 ]; then
            WHL="$WHL" RUST_SO_REL="$RUST_SO" "${HOST_PYTHON}" - <<'PYEOF'
import base64, hashlib, csv, os, zipfile, tempfile, shutil
whl = os.environ["WHL"]
rust_rel = os.environ["RUST_SO_REL"].lstrip("./")
tmp = tempfile.mkdtemp()
try:
    with zipfile.ZipFile(whl, 'r') as z: z.extractall(tmp)
    for root, _, files in os.walk(tmp):
        if 'RECORD' in files and '.dist-info' in root:
            rp = os.path.join(root, 'RECORD')
            with open(rp, 'r', newline='') as f: rows = list(csv.reader(f))
            for r in rows:
                if len(r) >= 3 and r[0] == rust_rel:
                    full = os.path.join(tmp, rust_rel)
                    with open(full, 'rb') as fh: data = fh.read()
                    d = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
                    r[1] = f'sha256={d}'; r[2] = str(len(data))
            with open(rp, 'w', newline='') as f: csv.writer(f).writerows(rows)
    out = whl + '.tmp'
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(tmp):
            for f in files:
                full = os.path.join(root, f)
                zf.write(full, os.path.relpath(full, tmp))
    shutil.move(out, whl)
finally: shutil.rmtree(tmp, ignore_errors=True)
PYEOF
        fi
        ;;
esac

exit 0