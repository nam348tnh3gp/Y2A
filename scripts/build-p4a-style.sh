#!/bin/bash
# build-p4a-style.sh — Generic p4a-style builder cho MỌI lib
#
# Usage:
#   bash scripts/build-p4a-style.sh <pkg_name> [extra_args...]
#
# Env từ workflow:
#   HOST_PY, TARGET_ROOT, TARGET_SITE, TARGET_STDLIB
#   CC, CXX, AR, RANLIB, STRIP, READELF
#   DEPS_INSTALL, NDK, NDK_SYSROOT, ANDROID_API
#   GITHUB_WORKSPACE

set -eo pipefail

PKG_NAME="$1"
shift || true

WHEELS_OUT="${WHEELS_OUT:-$GITHUB_WORKSPACE/wheels-out}"
TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
mkdir -p "$WHEELS_OUT" "$TMP_BUILD" "$SRC_DIR"

echo ""
echo "════════════════════════════════════════════"
echo "🔨 [p4a-style] Building: $PKG_NAME"
echo "════════════════════════════════════════════"

# ============================================================
# 1. TẢI SOURCE ĐỂ INSPECT
# ============================================================
cd "$SRC_DIR"
"$HOST_PY" -m pip download "$PKG_NAME" \
  --no-deps --no-binary=:all: \
  --dest="$SRC_DIR" 2>&1 | tail -3 || true

TARBALL=$(find "$SRC_DIR" -maxdepth 1 \( -name "*.tar.gz" -o -name "*.tar.xz" -o -name "*.tar.bz2" -o -name "*.zip" \) | head -1)

if [ -z "$TARBALL" ]; then
  echo "⚠️  Không tải được source cho $PKG_NAME — thử pip wheel trực tiếp"
  cd "$TMP_BUILD"
  "$HOST_PY" -m pip wheel "$PKG_NAME" \
    --no-deps --no-build-isolation \
    --wheel-dir "$WHEELS_OUT" 2>&1 | tail -30
  exit $?
fi

tar -xf "$TARBALL"
SRC_PATH=$(find "$SRC_DIR" -maxdepth 1 -type d -not -path "$SRC_DIR" | head -1)
echo "  Source: $SRC_PATH"

# ============================================================
# 2. DETECT BUILD BACKEND
# ============================================================
BACKEND="setuptools"
if [ -f "$SRC_PATH/pyproject.toml" ]; then
  BACKEND=$(grep -oE 'build-backend[[:space:]]*=[[:space:]]*"[^"]+"' "$SRC_PATH/pyproject.toml" 2>/dev/null \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/' || echo "setuptools")
  [ -z "$BACKEND" ] && BACKEND="setuptools"
fi

echo "  Backend: $BACKEND"

# ============================================================
# 3. WRAPPER SCRIPTS (p4a logic — safe cho mọi lib)
# ============================================================
cat > "$TMP_BUILD/target-python.sh" <<PYEOF
#!$HOST_PY
import sys, runpy, os
os.environ["_PYTHON_HOST_PLATFORM"] = "android-24-arm64_v8a"
if len(sys.argv) > 1:
    sys.argv = sys.argv[1:]
    runpy.run_path(sys.argv[0], run_name="__main__")
PYEOF
chmod +x "$TMP_BUILD/target-python.sh"

cat > "$TMP_BUILD/numpy-config" <<NCEOF
#!/bin/sh
if [ "\$1" = "--version" ]; then echo "2.5.3"; else echo "-I$TARGET_SITE/numpy/_core/include"; fi
NCEOF
chmod +x "$TMP_BUILD/numpy-config"

cat > "$TMP_BUILD/pybind11-config" <<PBEOF
#!/bin/sh
echo "-I$TARGET_SITE/pybind11/include"
PBEOF
chmod +x "$TMP_BUILD/pybind11-config"

export PATH="$TMP_BUILD:$TARGET_SITE/bin:/tmp/host-python/bin:$HOME/.cargo/bin:$PATH"

# ============================================================
# 4. ENV p4a-STYLE (safe cho mọi lib)
# ============================================================
export _PYTHON_HOST_PLATFORM="android-24-arm64_v8a"
export _PYTHON_PROJECT_BASE="$TARGET_ROOT"
export TARGET_PYTHON_EXE="$TARGET_ROOT/bin/python3.13"

# BLAS/LAPACK (chỉ numpy/scipy cần, nhưng safe cho mọi lib)
export NPY_BLAS_ORDER="openblas"
export NPY_LAPACK_ORDER="openblas"
export NPY_DISABLE_SVML=1
export NPY_USE_BLAS_ILP64=0
export OPENBLAS="$DEPS_INSTALL"
export BLAS="$DEPS_INSTALL"
export LAPACK="$DEPS_INSTALL"
export F77=""; export F90=""; export FC=""

# ============================================================
# 5. CHUẨN BỊ SETUP-ARGS THEO BACKEND
# ============================================================
SETUP_ARGS=()

case "$BACKEND" in
  *meson*)
    echo "  → Meson backend, dùng p4a setup-args"
    SETUP_ARGS=(
      "-Csetup-args=-Dblas=auto"
      "-Csetup-args=-Dlapack=auto"
      "-Csetup-args=-Dallow-noblas=False"
      "-Csetup-args=-Dbuildtype=release"
    )
    # longdouble_format cho ARM 64-bit
    SETUP_ARGS+=("-Csetup-args=-Dlongdouble_format=IEEE_QUAD_LE")
    ;;
  *setuptools*)
    echo "  → setuptools backend, không cần setup-args"
    ;;
  *maturin*)
    echo "  → Maturin (Rust) backend"
    export PYO3_PYTHON="$HOST_PY"
    export PYO3_CROSS=1
    export PYO3_CROSS_PYTHON_VERSION="3.13"
    export PYO3_CROSS_LIB_DIR="$TARGET_ROOT/lib"
    export PYO3_CROSS_INCLUDE_DIR="$TARGET_ROOT/include"
    ;;
  *flit*|*hatchling*|*poetry*)
    echo "  → Pure Python backend, không cần cross-compile"
    ;;
  *)
    echo "  → Unknown backend, thử không setup-args"
    ;;
esac

# ============================================================
# 6. PATCH ĐẶC BIỆT CHO TỪNG LIB
# ============================================================
case "$PKG_NAME" in
  Pillow|pillow|PIL)
    echo "  → Patch Pillow setup.py"
    cd "$SRC_PATH"
    cp setup.py setup.py.bak 2>/dev/null || true
    python3 - <<'PATCH_EOF'
import re, sys
try:
    with open('setup.py', 'r') as f:
        c = f.read()
    q1, q2 = chr(34), chr(39)
    for path in ['/usr/local/include', '/usr/include']:
        c = c.replace(q1+path+q1, q1+'/nonexistent/usrdir'+q1)
        c = c.replace(q2+path+q2, q2+'/nonexistent/usrdir'+q2)
    with open('setup.py', 'w') as f:
        f.write(c)
    print('Pillow patched')
except Exception as e:
    print(f'Pillow patch failed: {e}', file=sys.stderr)
PATCH_EOF
    ;;
  lxml)
    echo "  → Patch lxml setup.py (bỏ -lrt)"
    cd "$SRC_PATH"
    # lxml cần stub librt.a (đã tạo trong workflow)
    ;;
esac

# ============================================================
# 7. BUILD WHEEL
# ============================================================
cd "$SRC_PATH"

echo "  Running pip wheel with args: ${SETUP_ARGS[*]}"
echo ""

if [ "${#SETUP_ARGS[@]}" -gt 0 ]; then
  "$HOST_PY" -m pip wheel . \
    --no-deps --no-build-isolation \
    "${SETUP_ARGS[@]}" \
    --wheel-dir "$WHEELS_OUT" 2>&1 | tail -50
else
  "$HOST_PY" -m pip wheel . \
    --no-deps --no-build-isolation \
    --wheel-dir "$WHEELS_OUT" 2>&1 | tail -50
fi

RC=$?

if [ "$RC" -eq 0 ]; then
  echo "✅ [p4a-style] $PKG_NAME DONE"
else
  echo "❌ [p4a-style] $PKG_NAME FAILED (rc=$RC)"
fi

exit $RC
