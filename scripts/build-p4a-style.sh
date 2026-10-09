#!/bin/bash
set -eo pipefail

PKG_SPEC="${1:-}"
[ -z "$PKG_SPEC" ] && { echo "❌ Missing pkg"; exit 1; }
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
LOG="/tmp/p4a-${PKG_NAME}.log"

rm -rf "$TMP_BUILD"
mkdir -p "$SRC_DIR" "${TMP_BUILD}/bin"

echo "  Building: $PKG_SPEC"

# Symlink python tools
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python3"
ln -sf "${HOST_PYTHON}" "${TMP_BUILD}/bin/python"

# 1. Tải source
cd "$SRC_DIR"
if ! "${HOST_PYTHON}" -m pip download "$PKG_SPEC" \
        --no-deps --no-binary=:all: --dest="$SRC_DIR" > /tmp/dl.log 2>&1; then
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
mk ranlib "${AR}"
mk strip "${STRIP}"
mk readelf "${READELF}"

USE_SANDBOX=1
case "$PKG_NAME" in
    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
        USE_SANDBOX=0
        ;;
esac

if [ "$USE_SANDBOX" -eq 1 ]; then
    export PATH="${TMP_BUILD}/bin:${SANDBOX}:${TMP_BUILD}:${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:/usr/local/bin:${PATH}"
else
    export PATH="${TMP_BUILD}/bin:${TMP_BUILD}:${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:/usr/local/bin:${PATH}"
fi

# 5. Env
export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
export _PYTHON_PROJECT_BASE="${TARGET_ROOT}"
export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"

unset FC F77 F90

# [FIX] Cho Rust cc-rs: set rõ CC/CFLAGS cho target aarch64-linux-android
export CC_aarch64_linux_android="${NDK_CC}"
export CXX_aarch64_linux_android="${NDK_CXX}"
export AR_aarch64_linux_android="${NDK_AR}"
export CC_aarch64-linux-android="${NDK_CC}"
export CXX_aarch64-linux-android="${NDK_CXX}"
export AR_aarch64-linux-android="${NDK_AR}"
export CFLAGS_aarch64_linux_android="-fPIC -O2 -I${TARGET_ROOT}/include/python${PYTHON_MINOR} -I${DEPS_INSTALL}/include -Wno-implicit-function-declaration"
export CFLAGS_aarch64-linux-android="${CFLAGS_aarch64_linux_android}"
export LDFLAGS_aarch64_linux_android="-L${DEPS_INSTALL}/lib -L${TARGET_ROOT}/lib -Wl,--hash-style=both"

export CC="${NDK_CC}" CXX="${NDK_CXX}" AR="${NDK_AR}" RANLIB="${RANLIB}" STRIP="${STRIP}"
export CPP="${NDK_CC} -E" LD="${NDK_CC}" AS="${NDK_CC}"

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

# site.cfg
if [ -d "$SRC_PATH" ] && [ ! -f "$SRC_PATH/site.cfg" ]; then
    cat > "$SRC_PATH/site.cfg" <<EOF
[openblas]
libraries = openblas
library_dirs = ${DEPS_INSTALL}/lib
include_dirs = ${DEPS_INSTALL}/include
runtime_library_dirs = ${DEPS_INSTALL}/lib
EOF
fi

# 6. Setup args
SETUP_ARGS=()
PLAT_NAME_ARG=""

case "$BACKEND" in
    *meson*)
        case "$PKG_NAME" in
            numpy|scipy)
                # [FIX] Native file cho build_machine python3 + cython
                cat > "${TMP_BUILD}/native-tools.ini" <<EOF
[binaries]
python3 = '${HOST_PYTHON}'
cython = '${HOST_PY_PREFIX}/bin/cython'
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
exe_wrapper = '/bin/true'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
longdouble_format = 'IEEE_QUAD_LE'
needs_exe_wrapper = true
EOF
                SETUP_ARGS=(
                    "-Csetup-args=--cross-file=${TMP_BUILD}/android-cross.ini"
                    "-Csetup-args=--native-file=${TMP_BUILD}/native-tools.ini"
                    "-Csetup-args=-Dblas=openblas"
                    "-Csetup-args=-Dlapack=openblas"
                    "-Csetup-args=-Dallow-noblas=false"
                    "-Csetup-args=-Dbuildtype=release"
                )
                ;;
            *) SETUP_ARGS=(
                    "-Csetup-args=-Dblas=openblas"
                    "-Csetup-args=-Dlapack=openblas"
                    "-Csetup-args=-Dallow-noblas=false"
                    "-Csetup-args=-Dbuildtype=release"
               ) ;;
        esac
        ;;
    *maturin*)
        export PYO3_PYTHON="${HOST_PYTHON}"
        export PYO3_CROSS=1
        export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
        export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
        export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include"
        export PYO3_CONFIG_FILE="${PYO3_CONFIG}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${NDK_CC}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${TARGET_ROOT}/lib -C link-arg=-lpython${PYTHON_MINOR}"
        ;;
    *) PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}" ;;
esac

# 7. Patch đặc biệt
case "$PKG_NAME" in
    Pillow|pillow|PIL)
        echo "  → Patch Pillow"
        cd "$SRC_PATH"
        cp setup.py setup.py.bak 2>/dev/null || true
        cat > /tmp/patch_pillow.py <<'PYEOF'
import re
with open("setup.py", "r") as f:
    c = f.read()

# Filter string literals
q1, q2 = chr(34), chr(39)
skip = "/nonexistent/skip"
for path in ["/usr/include", "/usr/local/include", "/usr/lib",
             "/usr/local/lib", "/usr/lib/x86_64-linux-gnu", "/usr/lib64",
             "/opt/host-python/lib", "/opt/host-python/include",
             "/opt/host-python/bin"]:
    c = c.replace(q1+path+q1, q1+skip+q1)
    c = c.replace(q2+path+q2, q2+skip+q2)

c = re.sub(r"_add_directory\([^,]+,\s*[\x27\x22]/(usr|opt/host)[^\x27\x22]*[\x27\x22]\)", "pass", c)

# Inject filter AFTER module setup, BEFORE first setup() call
filter = '''
# ============ p4a filter ============
import os as _os
def _p4a_bad(p):
    p = str(p)
    for a in ("/work/python-android", "/work/deps-install", "/opt/ndk", "/tmp/p4a-build"):
        if a in p: return False
    for b in ("/usr/include", "/usr/local/include",
              "/usr/lib/x86_64-linux-gnu", "/usr/lib64", "/usr/lib",
              "/usr/local/lib", "/opt/host-python/lib",
              "/opt/host-python/include", "/opt/host-python/bin"):
        if p.startswith(b): return True
    return False
def _p4a_clean(l):
    if not l: return l
    return [d for d in l if not _p4a_bad(d)]

# Filter module-level
try:
    include_dirs[:] = _p4a_clean(include_dirs)
    library_dirs[:] = _p4a_clean(library_dirs)
except (NameError, UnboundLocalError):
    pass

# [FIX] Patch build_ext.finalize_options — filter mọi ext + self.library_dirs
try:
    from setuptools.command.build_ext import build_ext as _be_cls
    _orig_be_fo = _be_cls.finalize_options
    def _new_be_fo(self):
        _orig_be_fo(self)
        self.include_dirs = _p4a_clean(self.include_dirs)
        self.library_dirs = _p4a_clean(self.library_dirs)
        if getattr(self, 'rpath', None):
            self.rpath = _p4a_clean(self.rpath)
    _be_cls.finalize_options = _new_be_fo
except Exception:
    pass
# ============ end ============

'''
# Find LAST setup( call
matches = list(re.finditer(r'^(\s*)setup\(', c, re.MULTILINE))
if matches:
    m = matches[-1]
    idx = m.start()
    indent = m.group(1)
    indented = "\n".join((indent+l) if l.strip() else l for l in filter.split("\n"))
    c = c[:idx] + indented + c[idx:]

with open("setup.py", "w") as f:
    f.write(c)
PYEOF
        "${HOST_PYTHON}" /tmp/patch_pillow.py
        ;;

    cffi)
        export CFFI_PY_LIMITED_API="0x030D0000"
        SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=cp313")
        ;;

    zstandard)
        # cffi đã được sync trong entrypoint
        ;;
esac

# 8. Build
cd "$SRC_PATH"

BUILD_CMD=("${HOST_PYTHON}" -m pip wheel . --no-deps --no-build-isolation --wheel-dir "${WHEELS_OUT}")
[ -n "$PLAT_NAME_ARG" ] && BUILD_CMD+=("$PLAT_NAME_ARG")
[ "${#SETUP_ARGS[@]}" -gt 0 ] && BUILD_CMD+=("${SETUP_ARGS[@]}")

if "${BUILD_CMD[@]}" > "$LOG" 2>&1; then
    tail -5 "$LOG"
    echo "✅ $PKG_NAME built"
else
    RC=$?
    echo "--- pip log (tail 60) ---"
    tail -60 "$LOG"
    exit $RC
fi

# 9. Patch cryptography
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