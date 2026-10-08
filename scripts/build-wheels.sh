#!/bin/bash
# Build wheels trong container — p4a-style, không Tier 1
set -eo pipefail

HOST_PY="${HOST_PYTHON}"
TARGET_ROOT="${TARGET_ROOT}"
TARGET_STDLIB="${TARGET_STDLIB}"
TARGET_SITE="${TARGET_SITE}"
WHEELS_OUT="${WHEELS_OUT}"

mkdir -p "${WHEELS_OUT}"

# Sysconfig data của target
SYSCONF_FILE=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
if [ -z "$SYSCONF_FILE" ]; then
    echo "❌ Không có _sysconfigdata"
    exit 1
fi
SYSCONF_NAME=$(basename "$SYSCONF_FILE" .py)
SYSCONF_DIR="${WORKSPACE}/sysconfigdata-host"
rm -rf "$SYSCONF_DIR" && mkdir -p "$SYSCONF_DIR"
cp "$SYSCONF_FILE" "$SYSCONF_DIR/"

# Copy target include vào host python include
HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
mkdir -p "$HOST_INCLUDE"
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
[ -d "$TARGET_INCLUDE" ] && cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/"

# Ensure librt.a stub
mkdir -p "${DEPS_INSTALL}/lib"
[ ! -f "${DEPS_INSTALL}/lib/librt.a" ] && ${AR} rcs "${DEPS_INSTALL}/lib/librt.a"

# Env
export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
export _PYTHON_PROJECT_BASE="${TARGET_ROOT}"
export _PYTHON_SYSCONFIGDATA_NAME="${SYSCONF_NAME}"
export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"
export PYTHONPATH="${SYSCONF_DIR}:${TARGET_SITE}"
export PATH="${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:${PATH}"

export CFLAGS="-fPIC -O2 \
    -I${NDK_SYSROOT}/usr/include \
    -I${NDK_SYSROOT}/usr/include/aarch64-linux-android \
    -I${CLANG_BUILTIN} \
    -I${DEPS_INSTALL}/include \
    -I${TARGET_ROOT}/include/python${PYTHON_MINOR} \
    -Wno-implicit-function-declaration"
export CPPFLAGS="$CFLAGS"
export CXXFLAGS="$CFLAGS -I${DEPS_INSTALL}/include -L${DEPS_INSTALL}/lib"
export LDFLAGS="-L${DEPS_INSTALL}/lib -L${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API} -Wl,--hash-style=both"

export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

# PyO3
export PYO3_PYTHON="${HOST_PY}"
export PYO3_CROSS=1
export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include"

export CARGO_BUILD_TARGET="aarch64-linux-android"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${CC}"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${DEPS_INSTALL}/lib"
export OPENSSL_DIR="${DEPS_INSTALL}"
export OPENSSL_LIB_DIR="${DEPS_INSTALL}/lib"
export OPENSSL_INCLUDE_DIR="${DEPS_INSTALL}/include"

# Native packages — chỉ Tier 2 (p4a-style)
NATIVE_PACKAGES="cryptography bcrypt nh3 pydantic-core orjson tokenizers numpy scipy lxml Pillow pillow greenlet frozenlist ujson cffi aiohttp yarl multidict"

SUCCESS=""
FAIL=""

for pkg in $PKGLIST; do
    echo ""
    echo "════════════════════════════════════════"
    echo "📦 $pkg"
    echo "════════════════════════════════════════"

    # Skip nếu đã có wheel
    existing=$(ls -t "${WHEELS_OUT}"/${pkg//-/_}-*.whl "${WHEELS_OUT}"/${pkg}-*.whl 2>/dev/null | head -1 || true)
    if [ -n "$existing" ]; then
        echo "⏭️  Đã có wheel: $(basename "$existing")"
        continue
    fi

    if bash scripts/build-p4a-style.sh "$pkg" > "/tmp/build_${pkg}.log" 2>&1; then
        whl=$(ls -t "${WHEELS_OUT}"/${pkg//-/_}-*.whl "${WHEELS_OUT}"/${pkg}-*.whl 2>/dev/null | head -1 || true)
        if [ -n "$whl" ]; then
            echo "✅ $pkg — OK"
            SUCCESS="$SUCCESS $pkg"
        else
            echo "❌ $pkg — build OK nhưng không tìm thấy wheel"
            FAIL="$FAIL $pkg"
        fi
    else
        echo "❌ $pkg — FAILED"
        echo "--- log (tail 30) ---"
        tail -30 "/tmp/build_${pkg}.log" || true
        FAIL="$FAIL $pkg"
    fi
done

echo ""
echo "════════════════════════════════════════"
echo "📊 KẾT QUẢ"
echo "════════════════════════════════════════"
echo "✅ Success: $SUCCESS"
echo "❌ Failed:  $FAIL"
ls -lh "${WHEELS_OUT}/" || true

[ -n "$FAIL" ] && exit 1
exit 0