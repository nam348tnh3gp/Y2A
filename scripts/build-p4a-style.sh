#!/bin/bash
# build-p4a-style.sh — p4a-style builder với fix Pillow + numpy
set -eo pipefail

PKG_SPEC="${1:-}"
shift || true
if [ -z "$PKG_SPEC" ]; then echo "❌ Missing package name"; exit 1; fi
PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

HOST_PY="${HOST_PYTHON:-/tmp/host-python/bin/python3.13}"
WHEELS_OUT="${WHEELS_OUT:-$GITHUB_WORKSPACE/wheels-out}"
TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
SANDBOX="${TMP_BUILD}/sandbox-bin"
PYSITE="${TMP_BUILD}/pysite"
LOG="/tmp/p4a-${PKG_NAME}.log"
PY_MINOR="${PYTHON_MINOR:-3.13}"
ANDROID_TAG="${ANDROID_TAG:-android_24_arm64_v8a}"
NDK_PREBUILT="${NDK:-}/toolchains/llvm/prebuilt/linux-x86_64"

mkdir -p "$WHEELS_OUT" "$TMP_BUILD" "$SRC_DIR" "$SANDBOX" "$PYSITE"

echo ""; echo "════════════════════════════════════════════"
echo "🔨 [p4a-style] Building: $PKG_SPEC"
echo "════════════════════════════════════════════"
echo "  HOST_PY:     $HOST_PY"
echo "  TARGET_ROOT: $TARGET_ROOT"
echo "  ANDROID_TAG: $ANDROID_TAG"
echo "  CC:          $CC"
echo ""

# ============================================================
# 1. TẢI SOURCE
# ============================================================
cd "$SRC_DIR"
if ! "$HOST_PY" -m pip download "$PKG_SPEC" \
      --no-deps --no-binary=:all: \
      --dest="$SRC_DIR" > /tmp/dl.log 2>&1; then
  echo "⚠️  pip download failed, thử pip wheel trực tiếp"
  tail -20 /tmp/dl.log
  cd "$TMP_BUILD"
  if "$HOST_PY" -m pip wheel "$PKG_SPEC" \
        --no-deps --no-build-isolation \
        --wheel-dir "$WHEELS_OUT" > "$LOG" 2>&1; then
    tail -20 "$LOG"; exit 0
  else
    tail -60 "$LOG"; exit 1
  fi
fi

TARBALL=$(find "$SRC_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.xz" \
  -o -name "*.tar.bz2" -o -name "*.zip" \) | head -1)
[ -z "$TARBALL" ] && { echo "⚠️  Không tải được source"; exit 1; }

mkdir -p "$SRC_DIR/extracted"
tar -xf "$TARBALL" -C "$SRC_DIR/extracted"
SRC_PATH=$(find "$SRC_DIR/extracted" -maxdepth 1 -type d | tail -n +2 | head -1)
[ -z "$SRC_PATH" ] && SRC_PATH="$SRC_DIR/extracted"
echo "  Source: $SRC_PATH"

# ============================================================
# 2. DETECT BACKEND
# ============================================================
BACKEND=$(SRC_PATH="$SRC_PATH" "$HOST_PY" - <<'PYEOF'
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
# 3. WRAPPER SCRIPTS
# ============================================================
cat > "$TMP_BUILD/numpy-config" <<NCEOF
#!/bin/sh
if [ "\$1" = "--version" ]; then
  "$HOST_PY" -c 'import numpy; print(numpy.__version__)' 2>/dev/null || echo "0.0.0"
else
  echo "-I$TARGET_SITE/numpy/_core/include"
fi
NCEOF
chmod +x "$TMP_BUILD/numpy-config"

cat > "$TMP_BUILD/pybind11-config" <<PBEOF
#!/bin/sh
echo "-I$TARGET_SITE/pybind11/include"
PBEOF
chmod +x "$TMP_BUILD/pybind11-config"

# ============================================================
# 4. SANDBOX
# ============================================================
echo "  🔧 Tạo sandbox wrapper..."
rm -rf "$SANDBOX" && mkdir -p "$SANDBOX"

make_wrapper() {
  local name="$1" real="$2"
  cat > "$SANDBOX/$name" <<EOF
#!/bin/sh
exec "$real" "\$@"
EOF
  chmod +x "$SANDBOX/$name"
}

for n in gcc cc clang x86_64-linux-gnu-gcc aarch64-linux-gnu-gcc; do
  make_wrapper "$n" "$CC"
done
for n in g++ c++ clang++ x86_64-linux-gnu-g++ aarch64-linux-gnu-g++; do
  make_wrapper "$n" "$CXX"
done

LD_REAL="$NDK_PREBUILT/bin/ld.lld"
[ -x "$LD_REAL" ] || LD_REAL="$AR"
make_wrapper ld "$LD_REAL"
make_wrapper ar "$AR"
make_wrapper ranlib "$RANLIB"
make_wrapper strip "$STRIP"
make_wrapper nm "$NDK_PREBUILT/bin/llvm-nm"
make_wrapper objcopy "$NDK_PREBUILT/bin/llvm-objcopy"
make_wrapper objdump "$NDK_PREBUILT/bin/llvm-objdump"
make_wrapper readelf "$READELF"
make_wrapper gcc-ar "$AR"
make_wrapper gcc-ranlib "$RANLIB"

# ============================================================
# 5. ENV p4a-STYLE
# ============================================================
export PATH="$SANDBOX:$TMP_BUILD:$TARGET_SITE/bin:/tmp/host-python/bin:$HOME/.cargo/bin:$PATH"

echo "  which gcc:  $(which gcc 2>/dev/null || echo NOT_FOUND)"
echo "  which g++:  $(which g++ 2>/dev/null || echo NOT_FOUND)"

export _PYTHON_HOST_PLATFORM="$ANDROID_TAG"
export _PYTHON_PROJECT_BASE="$TARGET_ROOT"
export TARGET_PYTHON_EXE="$TARGET_ROOT/bin/python${PY_MINOR}"

export ac_cv_host="aarch64-linux-android"
export host_alias="aarch64-linux-android"

unset FC F77 F90

export CC="$CC"
export CXX="$CXX"
export CPP="$CC -E"
export LD="$CC"
export AR="$AR"
export AS="$CC"
export RANLIB="$RANLIB"
export STRIP="$STRIP"

# Hash-style chỉ trong LDFLAGS, không trong LDSHARED/CCSHARED
export LDSHARED="$CC -shared"
export CCSHARED="-fPIC"
export BLDSHARED="$CC -shared"
export LDCXXSHARED="$CXX -shared"

export CMAKE_C_COMPILER="$CC"
export CMAKE_CXX_COMPILER="$CXX"
export CMAKE_AR="$AR"
export CMAKE_RANLIB="$RANLIB"
export CMAKE_SYSTEM_NAME="Android"
export CMAKE_SYSTEM_PROCESSOR="aarch64"
export CMAKE_ANDROID_API="$ANDROID_API"

export ac_cv_prog_CC="$CC"
export ac_cv_prog_CXX="$CXX"

# KHÔNG dùng -nostdinc (chặn C++ headers)
export CFLAGS="-fPIC -O2 -I$DEPS_INSTALL/include -I$TARGET_ROOT/include/python${PY_MINOR} -Wno-implicit-function-declaration"
export CXXFLAGS="$CFLAGS"
export CPPFLAGS="$CFLAGS"
export LDFLAGS="-L$DEPS_INSTALL/lib -L$NDK_PREBUILT/sysroot/usr/lib/aarch64-linux-android/${ANDROID_API} -Wl,--hash-style=both"

export NPY_DISABLE_SVML=1
export NPY_USE_BLAS_ILP64=0
export NPY_BLAS_LIBS="-lopenblas"
export NPY_CBLAS_LIBS="-lopenblas"
export NPY_LAPACK_LIBS="-lopenblas"

# ============================================================
# 5.5. PyO3 config
# ============================================================
PYO3_CONFIG="$TMP_BUILD/pyo3-config.txt"
cat > "$PYO3_CONFIG" <<EOF
implementation=CPython
version=$PY_MINOR
shared=true
abi3=true
lib_name=python$PY_MINOR
lib_dir=$TARGET_ROOT/lib
executable=$TARGET_ROOT/bin/python$PY_MINOR
pointer_width=64
build_flags=
suppress_build_script_link_lines=false
EOF
export PYO3_CONFIG_FILE="$PYO3_CONFIG"

export RUSTFLAGS="-C link-arg=-L$TARGET_ROOT/lib -C link-arg=-lpython$PY_MINOR -C link-arg=-Wl,--hash-style=both"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$RUSTFLAGS"

# ============================================================
# 5.6. sitecustomize.py — patch LIBPL
# ============================================================
SYSCONF_DIR="$GITHUB_WORKSPACE/sysconfigdata-host"
SYSCONF_FILE=$(ls "$TARGET_ROOT/lib/python${PY_MINOR}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
SYSCONF_NAME=""
if [ -n "$SYSCONF_FILE" ]; then
  SYSCONF_NAME=$(basename "$SYSCONF_FILE" .py)
  mkdir -p "$SYSCONF_DIR"
  cp "$SYSCONF_FILE" "$SYSCONF_DIR/" 2>/dev/null || true
  echo "  Sysconfig: $SYSCONF_NAME"
fi

cat > "$PYSITE/sitecustomize.py" <<SITEEOF
import sysconfig
_target_lib = "$TARGET_ROOT/lib"
_target_inc = "$TARGET_ROOT/include/python${PY_MINOR}"
_patches = {
    'LIBPL': _target_lib,
    'LIBDIR': _target_lib,
    'LIBDEST': _target_lib,
    'INCLUDEPY': _target_inc,
    'CONFINCLUDEPY': _target_inc,
    'LIBRARY': 'python${PY_MINOR}',
    'LDLIBRARY': 'libpython${PY_MINOR}.so',
    'BLDLIBRARY': '-lpython${PY_MINOR}',
    'LIBPYTHON': 'python${PY_MINOR}',
    'LIBRARY_DEPS': '',
}
_orig_gcv = sysconfig.get_config_var
def _gcv(name):
    if name in _patches:
        return _patches[name]
    return _orig_gcv(name)
sysconfig.get_config_var = _gcv

_orig_gcvs = sysconfig.get_config_vars
def _gcvs(*args):
    v = _orig_gcvs(*args)
    if len(args) == 1 and isinstance(args[0], str):
        return _patches.get(args[0], v)
    if len(args) == 1 and isinstance(args[0], (list, tuple)):
        base = v or {}
        return {k: _patches.get(k, base.get(k)) for k in args[0]}
    if len(args) == 0 and isinstance(v, dict):
        out = dict(v)
        out.update(_patches)
        return out
    return v
sysconfig.get_config_vars = _gcvs

try:
    if sysconfig._CONFIG_VARS:
        sysconfig._CONFIG_VARS.update(_patches)
except Exception:
    pass
SITEEOF

export PYTHONPATH="$PYSITE:$SYSCONF_DIR:$TARGET_SITE:$PYTHONPATH"
if [ -n "$SYSCONF_NAME" ]; then
  export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
fi

# ============================================================
# 6. site.cfg numpy/scipy
# ============================================================
if [ -d "$SRC_PATH" ] && [ ! -f "$SRC_PATH/site.cfg" ]; then
  cat > "$SRC_PATH/site.cfg" <<EOF
[openblas]
libraries = openblas
library_dirs = $DEPS_INSTALL/lib
include_dirs = $DEPS_INSTALL/include
runtime_library_dirs = $DEPS_INSTALL/lib
EOF
fi

# ============================================================
# 7. SETUP-ARGS THEO BACKEND
# ============================================================
SETUP_ARGS=()
PLAT_NAME_ARG=""

case "$BACKEND" in
  *meson*)
    echo "  → Meson backend"
    PLAT_NAME_ARG=""
    SETUP_ARGS=(
      "-Csetup-args=-Dblas=openblas"
      "-Csetup-args=-Dlapack=openblas"
      "-Csetup-args=-Dallow-noblas=false"
      "-Csetup-args=-Dbuildtype=release"
    )
    ;;
  *maturin*)
    echo "  → Maturin (Rust)"
    PLAT_NAME_ARG=""
    export PYO3_PYTHON="$HOST_PY"
    export PYO3_CROSS=1
    export PYO3_CROSS_PYTHON_VERSION="$PY_MINOR"
    export PYO3_CROSS_LIB_DIR="$TARGET_ROOT/lib"
    export PYO3_CROSS_INCLUDE_DIR="$TARGET_ROOT/include"
    export PYO3_CONFIG_FILE="$PYO3_CONFIG"
    export RUSTFLAGS="-C link-arg=-L$TARGET_ROOT/lib -C link-arg=-lpython$PY_MINOR -C link-arg=-Wl,--hash-style=both"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$RUSTFLAGS"
    ;;
  *setuptools*|*)
    echo "  → Setuptools backend"
    PLAT_NAME_ARG="--config-settings=--build-option=--plat-name=${ANDROID_TAG}"
    ;;
esac

# ============================================================
# 8. PATCH ĐẶC BIỆT CHO TỪNG LIB
# ============================================================
case "$PKG_NAME" in
  # ---------- PILLOW: filter include_dirs/library_dirs ----------
  Pillow|pillow|PIL)
    echo "  → Patch Pillow setup.py (aggressive filter)"
    cd "$SRC_PATH"
    cp setup.py setup.py.bak 2>/dev/null || true

    cat > /tmp/patch_pillow.py <<'PYEOF'
import re
with open("setup.py", "r") as f:
    c = f.read()

# 1. Replace string literals
q1, q2 = chr(34), chr(39)
skip = "/nonexistent/skip"
for path in [
    "/usr/include", "/usr/local/include",
    "/usr/lib", "/usr/local/lib",
    "/tmp/host-python/include", "/tmp/host-python/lib",
]:
    c = c.replace(q1+path+q1, q1+skip+q1)
    c = c.replace(q2+path+q2, q2+skip+q2)

# 2. Replace _add_directory(_, "/usr/...") calls
c = re.sub(r"_add_directory\([^,]+,\s*[\x27\x22]/usr[^\x27\x22]*[\x27\x22]\)", "pass", c)

# 3. Inject filter right before setup() call
filter_code = '''
# ============ p4a-injected filter ============
import os as _os
_BAD_PREFIXES = (
    "/usr/include", "/usr/local/include",
    "/usr/lib", "/usr/local/lib",
    "/tmp/host-python/include", "/tmp/host-python/lib",
)
def _is_bad(p):
    p = str(p)
    pl = p.lower()
    if "android" in pl or "deps-install" in p or "python-android" in p:
        return False
    for b in _BAD_PREFIXES:
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
# ============ end p4a filter ============

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
print("Pillow patched (aggressive)")
PYEOF

    "$HOST_PY" /tmp/patch_pillow.py
    grep -c "_BAD_PREFIXES" setup.py || echo "(no filter)"
    ;;

  # ---------- NUMPY + SCIPY: cross-file với exe_wrapper ----------
  numpy|scipy)
    echo "  → $PKG_NAME: meson cross-file + OpenBLAS"
    cat > "$TMP_BUILD/android-cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'
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
      "-Csetup-args=--cross-file=$TMP_BUILD/android-cross.ini"
      "-Csetup-args=-Dblas=openblas"
      "-Csetup-args=-Dlapack=openblas"
      "-Csetup-args=-Dallow-noblas=false"
      "-Csetup-args=-Dbuildtype=release"
    )
    ;;

  # ---------- CFFI: stable ABI ----------
  cffi)
    echo "  → cffi: build với Py_LIMITED_API"
    export CFFI_PY_LIMITED_API="0x030D0000"
    SETUP_ARGS+=(
      "--config-settings=--build-option=--py-limited-api=cp313"
    )
    ;;

  # ---------- RUST packages ----------
  cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
    echo "  → $PKG_NAME: Rust + PyO3 link tường minh"
    export PYO3_PYTHON="$HOST_PY"
    export PYO3_CROSS=1
    export PYO3_CROSS_PYTHON_VERSION="$PY_MINOR"
    export PYO3_CROSS_LIB_DIR="$TARGET_ROOT/lib"
    export PYO3_CROSS_INCLUDE_DIR="$TARGET_ROOT/include"
    export PYO3_CONFIG_FILE="$PYO3_CONFIG"
    export RUSTFLAGS="-C link-arg=-L$TARGET_ROOT/lib -C link-arg=-lpython$PY_MINOR -C link-arg=-Wl,--hash-style=both"
    export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$RUSTFLAGS"
    ;;

  # ---------- LXML ----------
  lxml)
    echo "  → lxml: dùng stub librt.a + force CC"
    ;;

  # ---------- OTHER NATIVE (setuptools) ----------
  greenlet|frozenlist|ujson|markupsafe|regex|multidict|yarl|aiohttp|bitarray|brotli|mmh3|msgpack|lz4|zstandard|xxhash|pyrsistent|immutables|simplejson|pycryptodome|protobuf|pyyaml|cython)
    echo "  → $PKG_NAME: force CC/CXX/LDSHARED cho setuptools"
    ;;
esac

# ============================================================
# 9. BUILD WHEEL
# ============================================================
cd "$SRC_PATH"

echo ""
echo "  setup-args: ${SETUP_ARGS[*]}"
echo "  plat-name:  ${PLAT_NAME_ARG:-'(none)'}"
echo ""

RC=0
BUILD_CMD=("$HOST_PY" -m pip wheel . --no-deps --no-build-isolation --wheel-dir "$WHEELS_OUT")
[ -n "$PLAT_NAME_ARG" ] && BUILD_CMD+=("$PLAT_NAME_ARG")
[ "${#SETUP_ARGS[@]}" -gt 0 ] && BUILD_CMD+=("${SETUP_ARGS[@]}")

if "${BUILD_CMD[@]}" > "$LOG" 2>&1; then
  RC=0
else
  RC=$?
fi

# ============================================================
# 10. KẾT QUẢ
# ============================================================
if [ "$RC" -ne 0 ]; then
  echo "--- pip log (tail 60) ---"
  tail -60 "$LOG"
  echo "❌ [p4a-style] $PKG_NAME FAILED (rc=$RC)"
  exit $RC
fi

tail -20 "$LOG"
echo "✅ [p4a-style] $PKG_NAME DONE"

# ============================================================
# 11. VERIFY SANDBOX COMPILER
# ============================================================
echo ""
echo "🔍 Verify sandbox compiler..."
CT=$(mktemp --suffix=.c)
cat > "$CT" <<'EOF'
int main(void) { return 0; }
EOF
CO="${CT%.c}.o"
if gcc -c "$CT" -o "$CO" 2>/dev/null; then
  if readelf -h "$CO" 2>/dev/null | grep -q "AArch64"; then
    echo "  ✅ gcc wrapper → AArch64 ELF"
  else
    echo "  ❌ gcc wrapper không tạo AArch64 ELF"
  fi
fi
rm -f "$CT" "$CO"

# ============================================================
# 12. VERIFY WHEEL
# ============================================================
echo ""
echo "🔍 Verify wheel..."
GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
WHEEL_FOUND=0
for whl in "$WHEELS_OUT"/${PKG_NAME//-/_}-*.whl "$WHEELS_OUT"/${PKG_NAME}-*.whl; do
  [ -f "$whl" ] || continue
  WHEEL_FOUND=1
  base=$(basename "$whl")
  echo "  📦 $base"

  if [[ "$base" == *"${ANDROID_TAG}"* ]]; then
    echo "     ✅ tag OK"
  elif [[ "$base" == *"aarch64_linux_android"* ]]; then
    echo "     ⚠️  tag aarch64_linux_android — workflow sẽ rename"
  elif [[ "$base" == *"none-any"* ]]; then
    echo "     ⚠️  tag py3-none-any"
  else
    echo "     ⚠️  tag không chuẩn"
  fi

  work=$(mktemp -d)
  unzip -q -o "$whl" -d "$work"
  SO_COUNT=$(find "$work" -name "*.so" | wc -l)
  echo "     .so count: $SO_COUNT"
  bad=0
  while IFS= read -r so; do
    if readelf -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
      echo "     ❌ $(basename "$so") link glibc"
      bad=1
    fi
  done < <(find "$work" -name "*.so")
  rm -rf "$work"
  [ "$bad" -eq 0 ] && echo "     ✅ bionic OK"
done

[ "$WHEEL_FOUND" -eq 0 ] && echo "  ⚠️  Không tìm thấy wheel"

# ============================================================
# 13. VERIFY Rust extension
# ============================================================
case "$PKG_NAME" in
  cryptography|bcrypt|nh3|pydantic-core|orjson|tokenizers)
    echo ""
    echo "🔍 Verify Rust extension..."
    for whl in "$WHEELS_OUT"/${PKG_NAME//-/_}-*.whl "$WHEELS_OUT"/${PKG_NAME}-*.whl; do
      [ -f "$whl" ] || continue
      work=$(mktemp -d); unzip -q -o "$whl" -d "$work"
      RUST_SO=$(find "$work" -name "_rust*.so" -o -name "*.abi3.so" | head -1)
      if [ -n "$RUST_SO" ]; then
        if readelf -d "$RUST_SO" 2>/dev/null | grep -q "libpython${PY_MINOR}.so"; then
          echo "  ✅ $(basename "$whl") — có NEEDED libpython${PY_MINOR}.so"
        else
          echo "  ⚠️  $(basename "$whl") — không có NEEDED libpython (workflow sẽ patch)"
        fi
      fi
      rm -rf "$work"
    done
    ;;
esac

exit 0