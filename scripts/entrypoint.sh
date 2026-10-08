#!/bin/bash
# Entrypoint chạy trong Docker container
set -eo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🐳 p4a-style wheel builder"
echo "════════════════════════════════════════════════════════════"

source "${CARGO_HOME}/env" 2>/dev/null || true

# Workspace paths
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

mkdir -p "${TARGET_ROOT}" "${DEPS_INSTALL}" "${WHEELS_OUT}" "${WHEELS_FINAL}"

echo ""
echo "  TARGET_ROOT:     $TARGET_ROOT"
echo "  TARGET_STDLIB:   $TARGET_STDLIB"
echo "  TARGET_SITE:     $TARGET_SITE"
echo "  DEPS_INSTALL:    $DEPS_INSTALL"
echo "  HOST_PYTHON:     $HOST_PYTHON"
echo "  HOST_PY_PREFIX:  $HOST_PY_PREFIX"

# ════════════════════════════════════════════════════════════
# Cross-compile core deps
# ════════════════════════════════════════════════════════════
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo ""
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh
    touch "${DEPS_INSTALL}/.done"
else
    echo ""
    echo "⏭️  deps-install có sẵn — skip"
fi

# ════════════════════════════════════════════════════════════
# Cross-compile CPython
# ════════════════════════════════════════════════════════════
if [ ! -f "${TARGET_ROOT}/.python-built" ]; then
    echo ""
    echo "🔨 Cross-compile CPython..."
    bash scripts/cross-compile-python.sh
    touch "${TARGET_ROOT}/.python-built"
else
    echo ""
    echo "⏭️  python-android có sẵn — skip"
fi

# ════════════════════════════════════════════════════════════
# [FIX] Setup target sysconfigdata cho host python
# CPython cross-compile có _sysconfigdata__android_aarch64-linux-android.py
# nhưng host python (x86_64) không có. Copy để setuptools đọc được.
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Setup target sysconfig cho host python"

TARGET_SYSCONF=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
if [ -z "$TARGET_SYSCONF" ]; then
    echo "❌ Không tìm thấy _sysconfigdata trong ${TARGET_STDLIB}"
    echo "=== Content ==="
    ls -la "${TARGET_STDLIB}" | head -20 || true
    exit 1
fi

SYSCONF_NAME=$(basename "$TARGET_SYSCONF" .py)
HOST_PY_LIB="${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"

echo "  Source:  $TARGET_SYSCONF"
echo "  Target:  $HOST_PY_LIB/"
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"

export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
echo "  _PYTHON_SYSCONFIGDATA_NAME=$SYSCONF_NAME"

# [FIX] Copy thêm _sysconfigdata backup (một số package cần)
if [ -f "${TARGET_STDLIB}/_sysconfigdata__linux_aarch64.py" ]; then
    cp -v "${TARGET_STDLIB}/_sysconfigdata__linux_aarch64.py" "$HOST_PY_LIB/" || true
fi

# [FIX] Copy include headers từ target sang host
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    echo "  Copy headers: $TARGET_INCLUDE → $HOST_INCLUDE"
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/"
fi

# [FIX] Copy pyconfig.h cụ thể (nếu chưa có)
if [ -f "${TARGET_INCLUDE}/pyconfig.h" ] && [ ! -f "${HOST_INCLUDE}/pyconfig.h" ]; then
    cp -v "${TARGET_INCLUDE}/pyconfig.h" "${HOST_INCLUDE}/" || true
fi

# Verify sysconfig từ host python
echo ""
echo "  Verify: host python import sysconfig"
"${HOST_PYTHON}" -c "
import sysconfig
print('  LIBDIR:', sysconfig.get_config_var('LIBDIR'))
print('  INCLUDEPY:', sysconfig.get_config_var('INCLUDEPY'))
print('  CC:', sysconfig.get_config_var('CC'))
print('  Py_GIL_DISABLED:', sysconfig.get_config_var('Py_GIL_DISABLED'))
" || { echo "  ❌ Test failed"; exit 1; }

echo "  ✅ Sysconfig data OK"

# ════════════════════════════════════════════════════════════
# Bootstrap pip vào target site-packages
# ════════════════════════════════════════════════════════════
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo ""
    echo "🔨 Bootstrap pip..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        pip setuptools wheel
fi

# ════════════════════════════════════════════════════════════
# Read package list
# ════════════════════════════════════════════════════════════
if [ -n "${INPUT_PACKAGES}" ]; then
    LIST="${INPUT_PACKAGES}"
else
    LIST=$(grep -v '^#' wheels/list.txt | grep -v '^$' | tr '\n' ' ')
fi
CLEAN=""
for p in $LIST; do
    if echo "$p" | grep -qE '^[a-zA-Z][a-zA-Z0-9_.\-]*$'; then
        CLEAN="$CLEAN $p"
    fi
done
CLEAN=$(echo "$CLEAN" | xargs)
export PKGLIST="${CLEAN}"
echo ""
echo "📦 Packages: ${PKGLIST}"

# ════════════════════════════════════════════════════════════
# Build wheels
# ════════════════════════════════════════════════════════════
bash scripts/build-wheels.sh

# ════════════════════════════════════════════════════════════
# Post-process
# ════════════════════════════════════════════════════════════
bash scripts/post-process.sh

# ════════════════════════════════════════════════════════════
# Verify
# ════════════════════════════════════════════════════════════
bash scripts/verify-wheels.sh

# ════════════════════════════════════════════════════════════
# Release (chỉ khi có GH_TOKEN)
# ════════════════════════════════════════════════════════════
if [ -n "${GH_TOKEN}" ]; then
    bash scripts/release.sh
    bash scripts/gen-pip-index.sh
    bash scripts/commit-docs.sh
else
    echo "⚠️  Không có GH_TOKEN — bỏ qua release"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Build complete"
echo "════════════════════════════════════════════════════════════"
ls -lh "${WHEELS_FINAL}/" || true