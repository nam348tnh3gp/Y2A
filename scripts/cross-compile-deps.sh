#!/bin/bash
# Cross-compile core deps — p4a-style, dùng container
set -eo pipefail

cd /tmp
mkdir -p build-deps && cd build-deps

DEPS_INSTALL="${DEPS_INSTALL:?}"
TARGET_HOST="${TARGET_HOST:-aarch64-linux-android}"
ANDROID_API="${ANDROID_API:-24}"

COMMON_LDFLAGS="-Wl,--hash-style=both"
COMMON_CONFIGURE_FLAGS="--host=${TARGET_HOST} --prefix=${DEPS_INSTALL} --enable-static --disable-shared"

# [FIX] KHÔNG thêm DEPS_INSTALL/bin vào PATH nữa!
# Chỉ set PKG_CONFIG — không ảnh hưởng tar/xz/gcc host.
export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

echo "═══ libffi ═══"
wget -q "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
tar -xf "libffi-${LIBFFI_VERSION}.tar.gz"
cd "libffi-${LIBFFI_VERSION}"
./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) install
cd ..

echo "═══ OpenSSL ═══"
wget -q "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" \
    || wget -q "https://www.openssl.org/source/openssl-${OPENSSL_VERSION}.tar.gz"
tar -xf "openssl-${OPENSSL_VERSION}.tar.gz"
cd "openssl-${OPENSSL_VERSION}"
export ANDROID_NDK_ROOT="${NDK}"
LDFLAGS="${COMMON_LDFLAGS}" \
./Configure android-arm64 -D__ANDROID_API__=${ANDROID_API} \
    --prefix="${DEPS_INSTALL}" --openssldir="${DEPS_INSTALL}/ssl" \
    shared no-engine no-tests no-async \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" STRIP="${STRIP}"
make -j$(nproc)
make install_sw
cd ..

echo "═══ SQLite3 ═══"
SQLITE_URL="https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
wget -q "${SQLITE_URL}"
tar -xf "sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
cd "sqlite-autoconf-${SQLITE_VERSION}"
./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) install
cd ..

echo "═══ XZ ═══"
wget -q "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
tar -xf "xz-${XZ_VERSION}.tar.gz"
cd "xz-${XZ_VERSION}"
./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) install
# [FIX] Xoá xz binary ARM để tránh shadow host xz
rm -f "${DEPS_INSTALL}/bin/xz" "${DEPS_INSTALL}/bin/xzdec" "${DEPS_INSTALL}/bin/lzma"* "${DEPS_INSTALL}/bin/unxz" 2>/dev/null || true
cd ..

echo "═══ zlib ═══"
wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
tar -xf "zlib-${ZLIB_VERSION}.tar.gz"
cd "zlib-${ZLIB_VERSION}"
CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" ./configure --prefix="${DEPS_INSTALL}" --static
make -j$(nproc) install
cd ..

echo "═══ libxml2 ═══"
wget -q "https://download.gnome.org/sources/libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz"
tar -xf "libxml2-${LIBXML2_VERSION}.tar.xz"
cd "libxml2-${LIBXML2_VERSION}"
./configure ${COMMON_CONFIGURE_FLAGS} \
    --without-python --without-lzma --without-zlib --without-iconv --without-icu \
    LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) install
cd ..

# Verify xml2-config
if [ ! -x "${DEPS_INSTALL}/bin/xml2-config" ]; then
    echo "❌ xml2-config không tồn tại"
    exit 1
fi
echo "✅ xml2-config OK"

echo "═══ libxslt ═══"
wget -q "https://download.gnome.org/sources/libxslt/1.1/libxslt-${LIBXSLT_VERSION}.tar.xz"
tar -xf "libxslt-${LIBXSLT_VERSION}.tar.xz"
cd "libxslt-${LIBXSLT_VERSION}"

# [FIX] Tạm thời thêm DEPS_INSTALL/bin vào PATH + set XML_CONFIG
# để configure tìm thấy xml2-config, sau đó KHÔI PHỤC PATH
OLD_PATH="${PATH}"
export PATH="${DEPS_INSTALL}/bin:${PATH}"
export XML_CONFIG="${DEPS_INSTALL}/bin/xml2-config"

./configure ${COMMON_CONFIGURE_FLAGS} \
    --without-python --without-crypto \
    --with-libxml-prefix="${DEPS_INSTALL}" \
    --with-libxml-include-prefix="${DEPS_INSTALL}/include" \
    --with-libxml-libs-prefix="${DEPS_INSTALL}/lib" \
    XML_CONFIG="${DEPS_INSTALL}/bin/xml2-config" \
    LDFLAGS="${COMMON_LDFLAGS}"

# Khôi phục PATH để không ảnh hưởng bước sau
export PATH="${OLD_PATH}"
unset XML_CONFIG

make -j$(nproc) install
cd ..

echo "═══ libjpeg-turbo ═══"
wget -q "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEGTURBO_VERSION}/libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz"
tar -xf "libjpeg-turbo-${LIBJPEGTURBO_VERSION}.tar.gz"
cd "libjpeg-turbo-${LIBJPEGTURBO_VERSION}"
mkdir -p build && cd build
cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="${NDK}/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-${ANDROID_API} \
    -DCMAKE_INSTALL_PREFIX="${DEPS_INSTALL}" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF ..
ninja && ninja install
cd ../..

echo "═══ libpng ═══"
wget -q "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.gz" \
    || wget -q "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" -O "libpng-${LIBPNG_VERSION}.tar.gz"
tar -xf "libpng-${LIBPNG_VERSION}.tar.gz"
cd "libpng-${LIBPNG_VERSION}"
./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) install
cd ..

echo "═══ OpenBLAS ═══"
wget -q "https://github.com/OpenMathLib/OpenBLAS/releases/download/v${OPENBLAS_VERSION}/OpenBLAS-${OPENBLAS_VERSION}.tar.gz"
tar -xf "OpenBLAS-${OPENBLAS_VERSION}.tar.gz"
cd "OpenBLAS-${OPENBLAS_VERSION}"
make -j$(nproc) \
    TARGET=ARMV8 HOSTCC=gcc \
    CC="${CC}" CXX="${CXX}" AR="${AR}" RANLIB="${RANLIB}" \
    FC= NOFORTRAN=1 NOLAPACK=0 \
    USE_THREAD=1 USE_OPENMP=0 NUM_THREADS=64 \
    COMMON_OPT="-O2 -fPIC" CFLAGS="-O2 -fPIC -I${DEPS_INSTALL}/include"
make PREFIX="${DEPS_INSTALL}" install
cd ..

echo ""
echo "✅ All deps built"
echo ""
echo "=== DEPS_INSTALL/bin (chỉ .pc + config scripts, không có binary ARM) ==="
ls -la "${DEPS_INSTALL}/bin/" 2>/dev/null || true
echo ""
echo "=== DEPS_INSTALL/lib ==="
ls -lh "${DEPS_INSTALL}/lib/"*.a 2>/dev/null | head -20 || true