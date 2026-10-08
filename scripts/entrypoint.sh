#!/bin/bash
# Entrypoint chạy trong Docker container — CHỈ BUILD, không release
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
cp -v "$TARGET_SYSCONF" "$HOST_PY_LIB/"

export _PYTHON_SYSCONFIGDATA_NAME="$SYSCONF_NAME"
echo "  _PYTHON_SYSCONFIGDATA_NAME=$SYSCONF_NAME"

for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

echo "  Patch tất cả sysconfigdata để remove host paths"
for f in "${HOST_PY_LIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    sed -i "s|'/opt/host-python/lib'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'/usr/lib/x86_64-linux-gnu'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'/usr/local/lib'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'/usr/lib'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'/lib64'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'/lib'|'${TARGET_ROOT}/lib'|g" "$f"
    sed -i "s|'-L/opt/host-python/lib'|''|g" "$f"
    sed -i "s|'-L/usr/lib/x86_64-linux-gnu'|''|g" "$f"
    sed -i "s|'-L/usr/local/lib'|''|g" "$f"
    sed -i "s|'-L/usr/lib'|''|g" "$f"
    sed -i "s|/opt/host-python/include|${TARGET_ROOT}/include|g" "$f"
    sed -i "s|/usr/include|${TARGET_ROOT}/include|g" "$f"
done

# sitecustomize để subprocess tự set env
SITECUSTOMIZE="${HOST_PY_LIB}/sitecustomize.py"
cat > "$SITECUSTOMIZE" <<SITEEOF
import os
if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'
SITEEOF

# Copy headers
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true
fi

echo ""
echo "  Verify host python sysconfig:"
"${HOST_PYTHON}" -c "
import sysconfig
print('  LIBDIR:', sysconfig.get_config_var('LIBDIR'))
print('  INCLUDEPY:', sysconfig.get_config_var('INCLUDEPY'))
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
# 6. Build wheels
# ════════════════════════════════════════════════════════════
bash scripts/build-wheels.sh || true

# Kiểm tra có wheel không
WHEEL_COUNT=$(ls "${WHEELS_OUT}"/*.whl 2>/dev/null | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo "❌ Không có wheel nào được build"
    exit 1
fi
echo "✅ Có $WHEEL_COUNT wheel"

# ════════════════════════════════════════════════════════════
# 7. Post-process
# ════════════════════════════════════════════════════════════
bash scripts/post-process.sh || { echo "❌ Post-process FAILED"; exit 1; }

# ════════════════════════════════════════════════════════════
# 8. Verify (không fail workflow nếu 1 số wheel lỗi)
# ════════════════════════════════════════════════════════════
bash scripts/verify-wheels.sh || echo "⚠️  Verify có lỗi"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "✅ Build complete — sẽ release từ workflow"
echo "════════════════════════════════════════════════════════════"
ls -lh "${WHEELS_FINAL}/" || true

exit 0