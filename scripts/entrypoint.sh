#!/bin/bash
# Entrypoint chạy trong Docker container
# [FIX] Exit code phải propagate để workflow biết fail
set -eo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🐳 p4a-style wheel builder"
echo "════════════════════════════════════════════════════════════"

source "${CARGO_HOME}/env" 2>/dev/null || true

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
echo "  DEPS_INSTALL:    $DEPS_INSTALL"
echo "  HOST_PYTHON:     $HOST_PYTHON"

# ════════════════════════════════════════════════════════════
# 1. Cross-compile core deps
# ════════════════════════════════════════════════════════════
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo ""
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh || { echo "❌ cross-compile-deps.sh FAILED"; exit 1; }
    touch "${DEPS_INSTALL}/.done"
else
    echo ""
    echo "⏭️  deps-install có sẵn — skip"
fi

# ════════════════════════════════════════════════════════════
# 2. Cross-compile CPython
# ════════════════════════════════════════════════════════════
if [ ! -f "${TARGET_ROOT}/.python-built" ]; then
    echo ""
    echo "🔨 Cross-compile CPython..."
    bash scripts/cross-compile-python.sh || { echo "❌ cross-compile-python.sh FAILED"; exit 1; }
    touch "${TARGET_ROOT}/.python-built"
else
    echo ""
    echo "⏭️  python-android có sẵn — skip"
fi

# ════════════════════════════════════════════════════════════
# 3. Setup sysconfigdata cho host Python
# ════════════════════════════════════════════════════════════
echo ""
echo "🔧 Setup target sysconfig cho host python"

TARGET_SYSCONF=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
if [ -z "$TARGET_SYSCONF" ]; then
    echo "❌ Không tìm thấy _sysconfigdata"
    exit 1
fi

SYSCONF_NAME=$(basename "$TARGET_SYSCONF" .py)
HOST_PY_LIB="${HOST_PY_PREFIX}/lib/python${PYTHON_MINOR}"

echo "  Source:  $TARGET_SYSCONF"
echo "  Target:  $HOST_PY_LIB/"
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"

export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
echo "  _PYTHON_SYSCONFIGDATA_NAME=$SYSCONF_NAME"

# Copy all sysconfigdata files
for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

# [FIX] Patch sysconfigdata để remove host paths
HOST_SYSCONF="${HOST_PY_LIB}/${SYSCONF_NAME}.py"
if [ -f "$HOST_SYSCONF" ]; then
    echo "  Patch sysconfigdata để remove host paths"
    sed -i "s|'/opt/host-python/lib'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'/usr/lib/x86_64-linux-gnu'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'/usr/local/lib'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'/usr/lib'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'/lib64'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'/lib'|'${TARGET_ROOT}/lib'|g" "$HOST_SYSCONF"
    sed -i "s|'-L/opt/host-python/lib'|''|g" "$HOST_SYSCONF"
    sed -i "s|'-L/usr/lib/x86_64-linux-gnu'|''|g" "$HOST_SYSCONF"
    sed -i "s|'-L/usr/local/lib'|''|g" "$HOST_SYSCONF"
    sed -i "s|'-L/usr/lib'|''|g" "$HOST_SYSCONF"
fi

# Patch toàn bộ sysconfigdata files khác
for f in "${HOST_PY_LIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    [ "$f" = "$HOST_SYSCONF" ] && continue
    sed -i "s|'/opt/host-python/lib'|'${TARGET_ROOT}/lib'|g" "$f" 2>/dev/null || true
    sed -i "s|'/usr/lib/x86_64-linux-gnu'|'${TARGET_ROOT}/lib'|g" "$f" 2>/dev/null || true
    sed -i "s|'/usr/local/lib'|'${TARGET_ROOT}/lib'|g" "$f" 2>/dev/null || true
    sed -i "s|'/usr/lib'|'${TARGET_ROOT}/lib'|g" "$f" 2>/dev/null || true
done

# Copy headers
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    echo "  Copy headers: $TARGET_INCLUDE → $HOST_INCLUDE"
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true
fi

# Verify
echo ""
echo "  Verify host python sysconfig:"
"${HOST_PYTHON}" -c "
import sysconfig
print('  LIBDIR:', sysconfig.get_config_var('LIBDIR'))
print('  INCLUDEPY:', sysconfig.get_config_var('INCLUDEPY'))
print('  CC:', sysconfig.get_config_var('CC'))
" || { echo "  ❌ Verify failed"; exit 1; }
echo "  ✅ Sysconfig data OK"

# ════════════════════════════════════════════════════════════
# 4. Bootstrap pip
# ════════════════════════════════════════════════════════════
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo ""
    echo "🔨 Bootstrap pip..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        pip setuptools wheel || { echo "❌ Bootstrap pip FAILED"; exit 1; }
fi

# ════════════════════════════════════════════════════════════
# 5. Read package list
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
# 6. Build wheels — [FIX] exit non-zero nếu fail
# ════════════════════════════════════════════════════════════
if ! bash scripts/build-wheels.sh; then
    echo ""
    echo "════════════════════════════════════════════"
    echo "❌ BUILD WHEELS FAILED"
    echo "════════════════════════════════════════════"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# 7. Post-process
# ════════════════════════════════════════════════════════════
bash scripts/post-process.sh || { echo "❌ Post-process FAILED"; exit 1; }

# ════════════════════════════════════════════════════════════
# 8. Verify — fail nếu có wheel lỗi
# ════════════════════════════════════════════════════════════
if ! bash scripts/verify-wheels.sh; then
    echo "❌ Verify wheels FAILED"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# 9. Release — chỉ chạy khi có GH_TOKEN VÀ tất cả OK
# ════════════════════════════════════════════════════════════
if [ -n "${GH_TOKEN}" ]; then
    echo ""
    echo "🚀 Release..."
    bash scripts/release.sh || { echo "❌ Release FAILED"; exit 1; }
    bash scripts/gen-pip-index.sh || { echo "❌ Gen index FAILED"; exit 1; }
    bash scripts/commit-docs.sh || { echo "❌ Commit docs FAILED"; exit 1; }
else
    echo "⚠️  Không có GH_TOKEN — bỏ qua release"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Build complete"
echo "════════════════════════════════════════════════════════════"
ls -lh "${WHEELS_FINAL}/" || true