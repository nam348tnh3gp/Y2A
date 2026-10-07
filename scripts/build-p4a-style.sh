#!/bin/bash
# build-p4a-style.sh — Generic p4a-style builder cho MỌI lib
#
# Env BẮT BUỘC:
#   HOST_PYTHON, TARGET_ROOT, TARGET_SITE, TARGET_STDLIB
#   CC, CXX, AR, RANLIB, STRIP, READELF, CFLAGS, CPPFLAGS, LDFLAGS
#   DEPS_INSTALL, NDK, NDK_SYSROOT, ANDROID_API, GITHUB_WORKSPACE, PYTHON_MINOR

set -eo pipefail

PKG_SPEC="${1:-}"
shift || true

if [ -z "$PKG_SPEC" ]; then
  echo "❌ Missing package name"
  exit 1
fi

PKG_NAME="${PKG_SPEC%%[<>=!~]*}"

HOST_PY="${HOST_PYTHON:-/tmp/host-python/bin/python3.13}"
WHEELS_OUT="${WHEELS_OUT:-$GITHUB_WORKSPACE/wheels-out}"
TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
LOG="/tmp/p4a-${PKG_NAME}.log"
PY_MINOR="${PYTHON_MINOR:-3.13}"
ANDROID_TAG="${ANDROID_TAG:-android_24_arm64_v8a}"

mkdir -p "$WHEELS_OUT" "$TMP_BUILD" "$SRC_DIR"

echo ""
echo "════════════════════════════════════════════"
echo "🔨 [p4a-style] Building: $PKG_SPEC"
echo "════════════════════════════════════════════"
echo "  HOST_PY:     $HOST_PY"
echo "  TARGET_ROOT: $TARGET_ROOT"
echo "  WHEELS_OUT:  $WHEELS_OUT"
echo "  ANDROID_TAG: $ANDROID_TAG"

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
    tail -20 "$LOG"
    exit 0
  else
    echo "--- pip log (tail 60) ---"
    tail -60 "$LOG"
    exit 1
  fi
fi

TARBALL=$(find "$SRC_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.xz" \
  -o -name "*.tar.bz2" -o -name "*.zip" \) | head -1)

if [ -z "$TARBALL" ]; then
  echo "⚠️  Không tải được source cho $PKG_SPEC"
  exit 1
fi

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

export PATH="$TMP_BUILD:$TARGET_SITE/bin:/tmp/host-python/bin:$HOME/.cargo/bin:$PATH"

# ============================================================
# 4. ENV p4a-STYLE
# ============================================================
export _PYTHON_HOST_PLATFORM="$ANDROID_TAG"
export _PYTHON_PROJECT_BASE="$TARGET_ROOT"
export TARGET_PYTHON_EXE="$TARGET_ROOT/bin/python${PY_MINOR}"

unset FC F77 F90

export NPY_DISABLE_SVML=1
export NPY_USE_BLAS_ILP64=0
export NPY_BLAS_LIBS="-lopenblas"
export NPY_CBLAS_LIBS="-lopenblas"
export NPY_LAPACK_LIBS="-lopenblas"

# ============================================================
# 5. site.cfg cho numpy/scipy
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
# 6. SETUP-ARGS THEO BACKEND
# ============================================================
SETUP_ARGS=()

case "$BACKEND" in
  *meson*)
    echo "  → Meson backend"
    SETUP_ARGS=(
      "-Csetup-args=-Dblas=openblas"
      "-Csetup-args=-Dlapack=openblas"
      "-Csetup-args=-Dallow-noblas=false"
      "-Csetup-args=-Dbuildtype=release"
    )
    ;;
  *maturin*)
    echo "  → Maturin (Rust)"
    export PYO3_PYTHON="$HOST_PY"
    export PYO3_CROSS=1
    export PYO3_CROSS_PYTHON_VERSION="$PY_MINOR"
    export PYO3_CROSS_LIB_DIR="$TARGET_ROOT/lib"
    export PYO3_CROSS_INCLUDE_DIR="$TARGET_ROOT/include"
    ;;
  *)
    echo "  → $BACKEND backend"
    ;;
esac

# ============================================================
# 7. PATCH ĐẶC BIỆT CHO TỪNG LIB
# ============================================================
case "$PKG_NAME" in
  Pillow|pillow|PIL)
    echo "  → Patch Pillow setup.py"
    cd "$SRC_PATH"
    cp setup.py setup.py.bak 2>/dev/null || true

    cat > /tmp/patch_pillow.py <<'PYEOF'
import re
with open("setup.py", "r") as f:
    c = f.read()
q1, q2 = chr(34), chr(39)
skip = "/nonexistent/skip"
for path in ["/usr/include", "/usr/local/include", "/usr/lib", "/usr/local/lib"]:
    c = c.replace(q1+path+q1, q1+skip+q1)
    c = c.replace(q2+path+q2, q2+skip+q2)
c = re.sub(r"_add_directory\([^,]+,\s*[\x27\x22]/usr[^\x27\x22]*[\x27\x22]\)", "pass", c)
with open("setup.py", "w") as f:
    f.write(c)
print("Pillow patched")
PYEOF

    "$HOST_PY" /tmp/patch_pillow.py
    grep -c "nonexistent" setup.py || echo "(0)"

    export CC="$CC"
    export CXX="$CXX"
    export LD="$CC"
    export LDSHARED="$CC -shared"
    ;;

  # [FIX] Setuptools bỏ qua CC env — force lại + set sysconfig
  greenlet|frozenlist|ujson|markupsafe|regex|multidict|yarl|aiohttp|bitarray|brotli|mmh3|msgpack|lz4|zstandard|xxhash|pyrsistent|immutables|simplejson|pycryptodome|protobuf|pyyaml|cython)
    echo "  → $PKG_NAME: force CC/CXX/LDSHARED cho setuptools"
    export CC="$CC"
    export CXX="$CXX"
    export LD="$CC"
    export LDSHARED="$CC -shared"
    export CCSHARED="$CC -shared"
    ;;

  # [FIX] numpy 2.x dùng meson — cần cross-file
  numpy)
    echo "  → numpy: meson cross-file + OpenBLAS"
    cat > "$TMP_BUILD/android-cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'

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

  scipy)
    echo "  → scipy: meson cross-file + OpenBLAS"
    cat > "$TMP_BUILD/android-cross.ini" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
ranlib = '$RANLIB'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[properties]
needs_exe_wrapper = true
EOF
    SETUP_ARGS=(
      "-Csetup-args=--cross-file=$TMP_BUILD/android-cross.ini"
      "-Csetup-args=-Dblas=openblas"
      "-Csetup-args=-Dlapack=openblas"
      "-Csetup-args=-Dbuildtype=release"
    )
    ;;

  lxml)
    echo "  → lxml: dùng stub librt.a + force CC"
    export CC="$CC"
    export CXX="$CXX"
    export LDSHARED="$CC -shared"
    ;;

  cryptography)
    echo "  → cryptography: Rust build, sẽ patch RPATH ở workflow"
    ;;
esac

# ============================================================
# 8. BUILD WHEEL
# ============================================================
cd "$SRC_PATH"

echo "  setup-args: ${SETUP_ARGS[*]}"
echo ""

RC=0
if [ "${#SETUP_ARGS[@]}" -gt 0 ]; then
  if "$HOST_PY" -m pip wheel . \
        --no-deps --no-build-isolation \
        "${SETUP_ARGS[@]}" \
        --wheel-dir "$WHEELS_OUT" > "$LOG" 2>&1; then
    RC=0
  else
    RC=$?
  fi
else
  if "$HOST_PY" -m pip wheel . \
        --no-deps --no-build-isolation \
        --wheel-dir "$WHEELS_OUT" > "$LOG" 2>&1; then
    RC=0
  else
    RC=$?
  fi
fi

# ============================================================
# 9. KẾT QUẢ + VERIFY
# ============================================================
if [ "$RC" -ne 0 ]; then
  echo "--- pip log (tail 60) ---"
  tail -60 "$LOG"
  echo "❌ [p4a-style] $PKG_NAME FAILED (rc=$RC)"
  exit $RC
fi

tail -20 "$LOG"
echo "✅ [p4a-style] $PKG_NAME DONE"

echo ""
echo "🔍 Verify bionic..."
GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
for whl in "$WHEELS_OUT"/${PKG_NAME//-/_}-*.whl "$WHEELS_OUT"/${PKG_NAME}-*.whl; do
  [ -f "$whl" ] || continue
  work=$(mktemp -d)
  unzip -q -o "$whl" -d "$work"
  bad=0
  while IFS= read -r so; do
    if readelf -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
      echo "❌ $(basename "$whl") — $(basename "$so") link glibc"
      readelf -d "$so" | grep -E 'NEEDED' | grep -E "$GLIBC_PAT" | sed 's/^/   /'
      bad=1
    fi
  done < <(find "$work" -name "*.so")
  rm -rf "$work"
  if [ "$bad" -eq 0 ]; then
    echo "✅ $(basename "$whl")"
  fi
done

exit 0