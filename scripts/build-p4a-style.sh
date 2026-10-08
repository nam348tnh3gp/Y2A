#!/bin/bash
# build-p4a-style.sh — build 1 package cho Android
set -eo pipefail

PKG_SPEC="${1:-}"
if [ -z "$PKG_SPEC" ]; then echo "❌ Missing package name"; exit 1; fi
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
PYSITE="${TMP_BUILD}/pysite"
LOG="/tmp/p4a-${PKG_NAME}.log"

rm -rf "$TMP_BUILD"
mkdir -p "$SRC_DIR" "$PYSITE"

echo "  Building: $PKG_SPEC"
echo "  PKG_NAME: $PKG_NAME"

# ============================================================
# 0. Patch host sysconfig cho Pillow
# ============================================================
PATCHED_SYSCONF=""
restore_host_sysconf() {
    if [ -n "$PATCHED_SYSCONF" ] && [ -f "${PATCHED_SYSCONF}.p4a-bak" ]; then
        mv "${PATCHED_SYSCONF}.p4a-bak" "$PATCHED_SYSCONF"
    fi
}
trap restore_host_sysconf EXIT

case "$PKG_NAME" in
    Pillow|pillow|PIL)
        HS=$(find "${HOST_PY_PREFIX}/lib" -name "_sysconfigdata__*.py" | head -1)
        if [ -n "$HS" ]; then
            cp "$HS" "${HS}.p4a-bak"
            PATCHED_SYSCONF="$HS"
            HS="$HS" \
            TARGET_INC="${TARGET_ROOT}/include/python${PYTHON_MINOR}" \
            TARGET_LIB="${TARGET_ROOT}/lib" \
            "${HOST_PYTHON}" - <<'PYEOF'
import os, re
path = os.environ["HS"]
tinc = os.environ["TARGET_INC"]
tlib = os.environ["TARGET_LIB"]
with open(path, "r", encoding="utf-8") as f:
    c = f.read()
for old, new in [
    ('"/usr/include"', f'"{tinc}"'), ("'/usr/include'", f"'{tinc}'"),
    ('"/usr/local/include"', f'"{tinc}"'), ("'/usr/local/include'", f"'{tinc}'"),
    ('"/usr/lib"', f'"{tlib}"'), ("'/usr/lib'", f"'{tlib}'"),
    ('"/usr/local/lib"', f'"{tlib}"'), ("'/usr/local/lib'", f"'{tlib}'"),
    ('"/usr/lib/x86_64-linux-gnu"', f'"{tlib}"'), ("'/usr/lib/x86_64-linux-gnu'", f"'{tlib}'"),
    ('"/lib"', f'"{tlib}"'), ("'/lib'", f"'{tlib}'"),
    ('"/lib64"', f'"{tlib}"'), ("'/lib64'", f"'{tlib}'"),
    ('"/opt/host-python/lib"', f'"{tlib}"'), ("'/opt/host-python/lib'", f"'{tlib}'"),
]:
    c = c.replace(old, new)
for pat in [r'-I/usr/local/include\s*', r'-I/usr/include\s*',
            r'-L/usr/local/lib\s*', r'-L/usr/lib/x86_64-linux-gnu\s*',
            r'-L/usr/lib64\s*', r'-L/usr/lib\s*', r'-L/lib\s*',
            r'-L/opt/host-python/lib\s*']:
    c = re.sub(pat, '', c)
with open(path, "w", encoding="utf-8") as f:
    f.write(c)
PYEOF
        fi
        ;;
esac

# ============================================================
# 1. Tải source
# ============================================================
cd "$SRC_DIR"
if ! "${HOST_PYTHON}" -m pip download "$PKG_SPEC" \
        --no-deps --no-binary=:all: --dest="$SRC_DIR" > /tmp/dl.log 2>&1; then

    echo "⚠️  pip download failed — fetch sdist từ PyPI JSON"
    tail -10 /tmp/dl.log

    PKG_BASE="${PKG_SPEC%%[<>=!~]*}"
    PYPI_JSON=$(curl -sL "https://pypi.org/pypi/${PKG_BASE}/json" 2>/dev/null || echo "{}")
    SDIST_URL=$(echo "$PYPI_JSON" | "${HOST_PYTHON}" -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for u in d.get('urls', []):
        if u.get('packagetype') == 'sdist':
            print(u['url']); break
except Exception:
    pass
" 2>/dev/null || echo "")

    if [ -z "$SDIST_URL" ]; then
        echo "❌ Không tìm thấy sdist URL cho $PKG_BASE"
        exit 1
    fi

    echo "  → Download: $SDIST_URL"
    SDIST_NAME=$(basename "$SDIST_URL")
    wget -q "$SDIST_URL" -O "${SRC_DIR}/${SDIST_NAME}" || {
        echo "❌ Download sdist failed"; exit 1
    }
fi

TARBALL=$(find "$SRC_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.xz" \
    -o -name "*.tar.bz2" -o -name "*.zip" \) | head -1)
[ -z "$TARBALL" ] && { echo "❌ Không có source"; exit 1; }

mkdir -p "${SRC_DIR}/extracted"
tar -xf "$TARBALL" -C "${SRC_DIR}/extracted"
SRC_PATH=$(find "${SRC_DIR}/extracted" -maxdepth 1 -type d | tail -n +2 | head -1)
[ -z "$SRC_PATH" ] && SRC_PATH="${SRC_DIR}/extracted"
echo "  Source: $SRC_PATH"

# ============================================================
# 2. Detect backend
# ============================================================
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

# ============================================================
# 3. Wrapper scripts
# ============================================================
cat > "${TMP_BUILD}/numpy-config" <<NCEOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
  "${HOST_PYTHON}" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo "0.0.0"
else
  echo "-I${TARGET_SITE}/numpy/_core/include"
fi
NCEOF
chmod +x "${TMP_BUILD}/numpy-config"

# ============================================================
# 4. Sandbox compiler
# ============================================================
SANDBOX="${TMP_BUILD}/sandbox-bin"
mkdir -p "$SANDBOX"

make_wrapper() {
    local name="$1" real="$2"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$SANDBOX/$name"
    chmod +x "$SANDBOX/$name"
}

for n in gcc cc clang x86_64-linux-gnu-gcc aarch64-linux-gnu-gcc; do
    make_wrapper "$n" "${CC}"
done
for n in g++ c++ clang++ x86_64-linux-gnu-g++ aarch64-linux-gnu-g++; do
    make_wrapper "$n" "${CXX}"
done
make_wrapper ar "${AR}"
make_wrapper ranlib "${RANLIB}"
make_wrapper strip "${STRIP}"
make_wrapper readelf "${READELF}"

# ============================================================
# [FIX] Rust packages cần host cc cho build script → không dùng sandbox
# ============================================================
USE_SANDBOX=1
case "$PKG_NAME" in
    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
        USE_SANDBOX=0
        ;;
esac

if [ "$USE_SANDBOX" -eq 1 ]; then
    export PATH="${SANDBOX}:${TMP_BUILD}:${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:${PATH}"
else
    export PATH="${TMP_BUILD}:${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:${PATH}"
fi

# ============================================================
# 5. Env
# ============================================================
export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
export _PYTHON_PROJECT_BASE="${TARGET_ROOT}"
export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"

unset FC F77 F90

export CC CXX CPP="${CC} -E" LD="${CC}" AR AS="${CC}" RANLIB STRIP

export LDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"
export CCSHARED="-fPIC"
export BLDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"
export LDCXXSHARED="${CXX} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"

# [FIX] Bỏ -Wl,--hash-style=both khỏi LDFLAGS env — chỉ giữ trong LDSHARED
export LDFLAGS="-L${DEPS_INSTALL}/lib -L${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API}"

export CMAKE_C_COMPILER="${CC}"
export CMAKE_CXX_COMPILER="${CXX}"
export CMAKE_AR="${AR}"
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

# sitecustomize
cat > "${PYSITE}/sitecustomize.py" <<SITEEOF
import sysconfig
_patches = {
    'LIBPL': "${TARGET_ROOT}/lib",
    'LIBDIR': "${TARGET_ROOT}/lib",
    'LIBDEST': "${TARGET_ROOT}/lib",
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

export PYTHONPATH="${PYSITE}:${PYTHONPATH}"

# ============================================================
# 6. site.cfg cho numpy/scipy
# ============================================================
if [ -d "$SRC_PATH" ] && [ ! -f "$SRC_PATH/site.cfg" ]; then
    cat > "$SRC_PATH/site.cfg" <<EOF
[openblas]
libraries = openblas
library_dirs = ${DEPS_INSTALL}/lib
include_dirs = ${DEPS_INSTALL}/include
runtime_library_dirs = ${DEPS_INSTALL}/lib
EOF
fi

# ============================================================
# 7. Setup args theo backend
# ============================================================
SETUP_ARGS=()
PLAT_NAME_ARG=""

case "$BACKEND" in
    *meson*)
        echo "  → Meson backend"
        case "$PKG_NAME" in
            numpy|scipy)
                # [FIX] Thêm python3 binary cho link test
                cat > "${TMP_BUILD}/android-cross.ini" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
ranlib = '${RANLIB}'
python3 = '${HOST_PYTHON}'
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
                # [FIX] Native file cho meson
                cat > "${TMP_BUILD}/meson-native.ini" <<EOF
[binaries]
c = '/usr/bin/gcc'
cpp = '/usr/bin/g++'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
python3 = '${HOST_PYTHON}'
EOF
                SETUP_ARGS=(
                    "-Csetup-args=--cross-file=${TMP_BUILD}/android-cross.ini"
                    "-Csetup-args=--native-file=${TMP_BUILD}/meson-native.ini"
                    "-Csetup-args=-Dblas=openblas"
                    "-Csetup-args=-Dlapack=openblas"
                    "-Csetup-args=-Dallow-noblas=false"
                    "-Csetup-args=-Dbuildtype=release"
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
        export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include"
        export PYO3_CONFIG_FILE="${PYO3_CONFIG}"
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${TARGET_ROOT}/lib -C link-arg=-lpython${PYTHON_MINOR} -C link-arg=-Wl,--hash-style=both"
        unset RUSTFLAGS
        ;;
    *)
        echo "  → Setuptools backend"
        PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}"
        ;;
esac

# ============================================================
# 8. Patch đặc biệt
# ============================================================
case "$PKG_NAME" in
    Pillow|pillow|PIL)
        echo "  → Patch Pillow"
        cd "$SRC_PATH"
        cp setup.py setup.py.bak 2>/dev/null || true
        cat > /tmp/patch_pillow.py <<'PYEOF'
import re
with open("setup.py", "r") as f:
    c = f.read()
q1, q2 = chr(34), chr(39)
skip = "/nonexistent/skip"
for path in ["/usr/include", "/usr/local/include", "/usr/lib", "/usr/local/lib",
             "/opt/host-python/lib", "/opt/host-python/include"]:
    c = c.replace(q1+path+q1, q1+skip+q1)
    c = c.replace(q2+path+q2, q2+skip+q2)
c = re.sub(r"_add_directory\([^,]+,\s*[\x27\x22]/(usr|opt/host)[^\x27\x22]*[\x27\x22]\)", "pass", c)
filter_code = '''
import os as _os
_BAD = ("/usr/include", "/usr/local/include", "/usr/lib", "/usr/local/lib",
        "/opt/host-python/lib", "/opt/host-python/include")
def _is_bad(p):
    p = str(p)
    pl = p.lower()
    if "android" in pl or "deps-install" in p or "python-android" in p:
        return False
    for b in _BAD:
        if p.startswith(b): return True
    return False
try:
    include_dirs[:] = [d for d in include_dirs if not _is_bad(d)]
    library_dirs[:] = [d for d in library_dirs if not _is_bad(d)]
except (NameError, UnboundLocalError):
    pass
try:
    for _ext in ext_modules:
        if hasattr(_ext, "include_dirs") and _ext.include_dirs:
            _ext.include_dirs = [d for d in _ext.include_dirs if not _is_bad(d)]
        if hasattr(_ext, "library_dirs") and _ext.library_dirs:
            _ext.library_dirs = [d for d in _ext.library_dirs if not _is_bad(d)]
except (NameError, UnboundLocalError):
    pass

'''
m = re.search(r'^(\s*)setup\(', c, re.MULTILINE)
if m:
    idx = m.start()
    indent = m.group(1)
    indented = "\n".join(
        (indent + line) if line.strip() else line
        for line in filter_code.split("\n")
    )
    c = c[:idx] + indented + c[idx:]
with open("setup.py", "w") as f:
    f.write(c)
PYEOF
        "${HOST_PYTHON}" /tmp/patch_pillow.py
        ;;

    cffi)
        echo "  → cffi: Py_LIMITED_API"
        export CFFI_PY_LIMITED_API="0x030D0000"
        SETUP_ARGS+=("--config-settings=--build-option=--py-limited-api=cp313")
        ;;

    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
        echo "  → $PKG_NAME: Rust + PyO3"
        export PYO3_PYTHON="${HOST_PYTHON}"
        export PYO3_CROSS=1
        export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
        export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
        export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include"
        export PYO3_CONFIG_FILE="${PYO3_CONFIG}"
        # [FIX] Chỉ target-specific RUSTFLAGS, không global
        export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${TARGET_ROOT}/lib -C link-arg=-lpython${PYTHON_MINOR} -C link-arg=-Wl,--hash-style=both"
        unset RUSTFLAGS
        ;;
esac

# ============================================================
# 9. Build
# ============================================================
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

# ============================================================
# 10. Patch cryptography NEEDED libpython
# ============================================================
case "$PKG_NAME" in
    cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
        pkg_under=$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
        pkg_lower=$(echo "$PKG_NAME" | tr '[:upper:]' '[:lower:]')
        WHL=$(ls -t "${WHEELS_OUT}"/${pkg_under}-*.whl \
                    "${WHEELS_OUT}"/${pkg_lower}-*.whl \
                    "${WHEELS_OUT}"/${PKG_NAME}-*.whl 2>/dev/null | head -1 || true)
        if [ -n "$WHL" ]; then
            WHL=$(realpath "$WHL")
            WORK="/tmp/patch-${PKG_NAME}"
            rm -rf "$WORK" && mkdir -p "$WORK"
            cd "$WORK"
            unzip -o -q "$WHL"
            RUST_SO=$(find . -name "_rust*.so" -o -name "*.abi3.so" | head -1)
            if [ -n "$RUST_SO" ]; then
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
    with zipfile.ZipFile(whl, 'r') as z:
        z.extractall(tmp)
    for root, _, files in os.walk(tmp):
        if 'RECORD' in files and '.dist-info' in root:
            rp = os.path.join(root, 'RECORD')
            with open(rp, 'r', newline='') as f:
                rows = list(csv.reader(f))
            for r in rows:
                if len(r) >= 3 and r[0] == rust_rel:
                    full = os.path.join(tmp, rust_rel)
                    with open(full, 'rb') as fh:
                        data = fh.read()
                    d = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
                    r[1] = f'sha256={d}'
                    r[2] = str(len(data))
            with open(rp, 'w', newline='') as f:
                csv.writer(f).writerows(rows)
    out = whl + '.tmp'
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as zf:
        for root, _, files in os.walk(tmp):
            for f in files:
                full = os.path.join(root, f)
                zf.write(full, os.path.relpath(full, tmp))
    shutil.move(out, whl)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
                fi
            fi
        fi
        ;;
esac

exit 0