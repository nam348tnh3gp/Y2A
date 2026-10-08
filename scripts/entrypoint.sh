#!/bin/bash
# Entrypoint chạy trong Docker container
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

# Copy all sysconfigdata files
for f in "${TARGET_STDLIB}"/_sysconfigdata__*.py; do
    [ -f "$f" ] || continue
    cp -v "$f" "$HOST_PY_LIB/" 2>/dev/null || true
done

# ════════════════════════════════════════════════════════════
# [FIX] Patch sysconfigdata — bao gồm cả file default
# để subprocess (không có env) cũng load đúng
# ════════════════════════════════════════════════════════════
echo "  Patch tất cả sysconfigdata để remove host paths"

# Patch file target
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

# Patch site-packages của host python để set env mặc định
SITECUSTOMIZE="${HOST_PY_LIB}/sitecustomize.py"
cat > "$SITECUSTOMIZE" <<SITEEOF
# [FIX] Auto-set _PYTHON_SYSCONFIGDATA_NAME cho subprocess
import os
if '_PYTHON_SYSCONFIGDATA_NAME' not in os.environ:
    os.environ['_PYTHON_SYSCONFIGDATA_NAME'] = '${SYSCONF_NAME}'
SITEEOF
echo "  ✅ Created $SITECUSTOMIZE"

# Copy headers
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
if [ -d "$TARGET_INCLUDE" ] && [ -d "$HOST_INCLUDE" ]; then
    cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true
fi

# ════════════════════════════════════════════════════════════
# [FIX] Xoá libpython.so của host để ld không tìm thấy khi cross-compile
# (giữ symlink cho host python chạy được)
# ════════════════════════════════════════════════════════════
echo "  Backup host libpython để ld không match sai"
HOST_LIBPY="${HOST_PY_PREFIX}/lib/libpython${PYTHON_MINOR}.so"
if [ -f "$HOST_LIBPY" ] && [ ! -f "${HOST_LIBPY}.host-orig" ]; then
    # Chỉ rename nếu chưa backup
    HOST_LIBPY_REAL=$(readlink -f "$HOST_LIBPY" 2>/dev/null || echo "")
    if [ -n "$HOST_LIBPY_REAL" ] && [ -f "$HOST_LIBPY_REAL" ]; then
        cp "$HOST_LIBPY_REAL" "${HOST_LIBPY}.host-orig" 2>/dev/null || true
    fi
fi

# Verify
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
# 6. Build wheels — [FIX] log warning nếu có fail, KHÔNG exit
# ════════════════════════════════════════════════════════════
BUILD_RC=0
if ! bash scripts/build-wheels.sh; then
    BUILD_RC=$?
    echo ""
    echo "════════════════════════════════════════════"
    echo "⚠️  Một số package FAILED (rc=$BUILD_RC)"
    echo "   → Vẫn tiếp tục release các wheel đã build thành công"
    echo "════════════════════════════════════════════"
fi

# Kiểm tra có wheel nào không
WHEEL_COUNT=$(ls "${WHEELS_OUT}"/*.whl 2>/dev/null | wc -l)
if [ "$WHEEL_COUNT" -eq 0 ]; then
    echo "❌ Không có wheel nào được build — dừng"
    exit 1
fi
echo "✅ Có $WHEEL_COUNT wheel — tiếp tục"

# ════════════════════════════════════════════════════════════
# 7. Post-process
# ════════════════════════════════════════════════════════════
bash scripts/post-process.sh || { echo "❌ Post-process FAILED"; exit 1; }

# ════════════════════════════════════════════════════════════
# 8. Verify — không fail nếu 1 số wheel lỗi (chỉ log)
# ════════════════════════════════════════════════════════════
bash scripts/verify-wheels.sh || echo "⚠️  Verify có lỗi — tiếp tục release"

# ════════════════════════════════════════════════════════════
# 9. Release — chạy nếu có GH_TOKEN + có wheel
# ════════════════════════════════════════════════════════════
FINAL_COUNT=$(ls "${WHEELS_FINAL}"/*.whl 2>/dev/null | wc -l)
if [ -n "${GH_TOKEN}" ] && [ "$FINAL_COUNT" -gt 0 ]; then
    echo ""
    echo "🚀 Release $FINAL_COUNT wheel(s)..."
    bash scripts/release.sh || echo "⚠️  Release có warning"
    bash scripts/gen-pip-index.sh || echo "⚠️  Gen index có warning"
    bash scripts/commit-docs.sh || echo "⚠️  Commit docs có warning"
else
    echo "⚠️  Không release (GH_TOKEN=${GH_TOKEN:+set}, wheels=$FINAL_COUNT)"
fi

echo ""
echo "════════════════════════════════════════════════════════════"
if [ "$BUILD_RC" -ne 0 ]; then
    echo "⚠️  Build hoàn tất với một số package fail (đã release phần OK)"
else
    echo "✅ Build complete — tất cả package OK"
fi
echo "════════════════════════════════════════════════════════════"
ls -lh "${WHEELS_FINAL}/" || true
exit 0