#!/bin/bash
# Entrypoint chạy trong Docker container.
# Orchestrate: setup → cross-compile CPython → build wheels → post-process → release.
set -eo pipefail

echo "════════════════════════════════════════════════════════════"
echo "🐳 p4a-style wheel builder"
echo "════════════════════════════════════════════════════════════"
echo "  PYTHON_VERSION:  ${PYTHON_VERSION}"
echo "  ANDROID_TAG:     ${ANDROID_TAG}"
echo "  NDK:             ${NDK}"
echo "  HOST_PYTHON:     ${HOST_PYTHON}"
echo "  CC:              ${CC}"
echo ""

source "${CARGO_HOME}/env" 2>/dev/null || true

# ============================================================
# 1. Setup workspace paths
# ============================================================
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

mkdir -p "${TARGET_ROOT}" "${DEPS_INSTALL}" "${WHEELS_OUT}" "${WHEELS_FINAL}"

# ============================================================
# 2. Cross-compile core deps (nếu chưa có)
# ============================================================
if [ ! -f "${DEPS_INSTALL}/.done" ]; then
    echo "🔨 Cross-compile core deps..."
    bash scripts/cross-compile-deps.sh
    touch "${DEPS_INSTALL}/.done"
else
    echo "⏭️  deps-install có sẵn — skip"
fi

# ============================================================
# 3. Cross-compile CPython (nếu chưa có)
# ============================================================
if [ ! -f "${TARGET_ROOT}/.python-built" ]; then
    echo "🔨 Cross-compile CPython..."
    bash scripts/cross-compile-python.sh
    touch "${TARGET_ROOT}/.python-built"
else
    echo "⏭️  python-android có sẵn — skip"
fi

# ============================================================
# 4. Bootstrap pip vào target site-packages
# ============================================================
if [ ! -d "${TARGET_SITE}/pip" ]; then
    echo "🔨 Bootstrap pip..."
    ${HOST_PYTHON} -m pip install \
        --target="${TARGET_SITE}" \
        --no-deps --no-cache-dir --only-binary=:all: \
        pip setuptools wheel
fi

# ============================================================
# 5. Đọc package list
# ============================================================
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
echo "📦 Packages: ${PKGLIST}"
echo ""

# ============================================================
# 6. Build wheels
# ============================================================
bash scripts/build-wheels.sh

# ============================================================
# 7. Post-process (rename tags)
# ============================================================
bash scripts/post-process.sh

# ============================================================
# 8. Verify
# ============================================================
bash scripts/verify-wheels.sh

# ============================================================
# 9. Release + pip index (chỉ khi có GH_TOKEN)
# ============================================================
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