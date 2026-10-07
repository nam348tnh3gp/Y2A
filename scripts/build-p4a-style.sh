#!/bin/bash
# build-p4a-style.sh — Generic p4a-style builder cho MỌI lib
#
# Env BẮT BUỘC đã export:
#   HOST_PYTHON, TARGET_ROOT, TARGET_SITE, TARGET_STDLIB
#   CC, CXX, AR, RANLIB, STRIP, READELF, CFLAGS, CPPFLAGS, LDFLAGS
#   DEPS_INSTALL, NDK, NDK_SYSROOT, ANDROID_API, GITHUB_WORKSPACE

set -eo pipefail

PKG_NAME="${1:-}"
shift || true

if [ -z "$PKG_NAME" ]; then
  echo "❌ Missing package name"
  exit 1
fi

HOST_PY="${HOST_PYTHON:-/tmp/host-python/bin/python3.13}"
WHEELS_OUT="${WHEELS_OUT:-$GITHUB_WORKSPACE/wheels-out}"
TMP_BUILD="/tmp/p4a-build-${PKG_NAME}"
SRC_DIR="${TMP_BUILD}/src"
mkdir -p "$WHEELS_OUT" "$TMP_BUILD" "$SRC_DIR"

echo ""
echo "════════════════════════════════════════════"
echo "🔨 [p4a-style] Building: $PKG_NAME"
echo "════════════════════════════════════════════"
echo "  HOST_PY:     $HOST_PY"
echo "  TARGET_ROOT: $TARGET_ROOT"
echo "  WHEELS_OUT:  $WHEELS_OUT"

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
# 3. WRAPPER SCRIPTS
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
# 4. ENV p4a-STYLE
# ============================================================
export _PYTHON_HOST_PLATFORM="android-24-arm64_v8a"
export _PYTHON_PROJECT_BASE="$TARGET_ROOT"
export TARGET_PYTHON_EXE="$TARGET_ROOT/bin/python3.13"

export NPY_BLAS_ORDER="openblas"
export NPY_LAPACK_ORDER="openblas"
export NPY_DISABLE_SVML=1
export NPY_USE_BLAS_ILP64=0
export OPENBLAS="$DEPS_INSTALL"
export BLAS="$DEPS_INSTALL"
export LAPACK="$DEPS_INSTALL"
export F77=""; export F90=""; export FC=""

# ============================================================
# 5. SETUP-ARGS THEO BACKEND
# ============================================================
SETUP_ARGS=()

case "$BACKEND" in
  *meson*)
    echo "  → Meson backend"
    SETUP_ARGS=(
      "-Csetup-args=-Dblas=auto"
      "-Csetup-args=-Dlapack=auto"
      "-Csetup-args=-Dallow-noblas=False"
      "-Csetup-args=-Dbuildtype=release"
      "-Csetup-args=-Dlongdouble_format=IEEE_QUAD_LE"
    )
    ;;
  *maturin*)
    echo "  → Maturin (Rust)"
    export PYO3_PYTHON="$HOST_PY"
    export PYO3_CROSS=1
    export PYO3_CROSS_PYTHON_VERSION="3.13"
    export PYO3_CROSS_LIB_DIR="$TARGET_ROOT/lib"
    export PYO3_CROSS_INCLUDE_DIR="$TARGET_ROOT/include"
    ;;
  *)
    echo "  → $BACKEND backend"
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

    # Dùng printf để tạo script Python (tránh YAML heredoc)
    printf '%s\n' \
      'import re, sys' \
      'with open("setup.py", "r") as f:' \
      '    c = f.read()' \
      'q1, q2 = chr(34), chr(39)' \
      'skip = "/nonexistent/skip"' \
      'for path in ["/usr/include", "/usr/local/include", "/usr/lib", "/usr/local/lib"]:' \
      '    c = c.replace(q1+path+q1, q1+skip+q1)' \
      '    c = c.replace(q2+path+q2, q2+skip+q2)' \
      'c = re.sub(r"_add_directory\([^,]+,\s*[\x27\x22]/usr[^\x27\x22]*[\x27\x22]\)", "pass", c)' \
      'with open("setup.py", "w") as f:' \
      '    f.write(c)' \
      'print("Pillow patched")' \
      > /tmp/patch_pillow.py

    python3 /tmp/patch_pillow.py
    grep -c "nonexistent" setup.py || echo "(0)"
    ;;
  lxml)
    echo "  → lxml: dùng stub librt.a"
    ;;
esac

# ============================================================
# 7. BUILD WHEEL
# ============================================================
cd "$SRC_PATH"

echo "  setup-args: ${SETUP_ARGS[*]}"
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