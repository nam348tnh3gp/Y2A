#!/bin/bash
# Cross-compile core deps cho Android wheels.
set -eo pipefail

cd /tmp
mkdir -p build-deps && cd build-deps

DEPS_INSTALL="${DEPS_INSTALL:?}"
TARGET_HOST="${TARGET_HOST:-aarch64-linux-android}"
ANDROID_API="${ANDROID_API:-24}"

COMMON_LDFLAGS="-Wl,--hash-style=both"
COMMON_CONFIGURE_FLAGS="--host=${TARGET_HOST} --prefix=${DEPS_INSTALL} --enable-static --disable-shared"

export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

echo "════════════════════════════════════════════"
echo "  Cross-compiling core deps"
echo "════════════════════════════════════════════"

# ═══════════════════════════════════════════════════════════
# libffi
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ libffi ═══"
wget -q "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
tar -xf "libffi-${LIBFFI_VERSION}.tar.gz"
cd "libffi-${LIBFFI_VERSION}"
CFLAGS="-fPIC -O2" ./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) CFLAGS="-fPIC -O2" install
cd ..

# ═══════════════════════════════════════════════════════════
# OpenSSL
# ═══════════════════════════════════════════════════════════
echo ""
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

# ═══════════════════════════════════════════════════════════
# SQLite3
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ SQLite3 ═══"
SQLITE_URL="https://www.sqlite.org/${SQLITE_YEAR}/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
if ! curl --output /dev/null --silent --head --fail "$SQLITE_URL"; then
    SQLITE_URL="https://www.sqlite.org/2023/sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
fi
wget -q "${SQLITE_URL}"
tar -xf "sqlite-autoconf-${SQLITE_VERSION}.tar.gz"
cd "sqlite-autoconf-${SQLITE_VERSION}"
CFLAGS="-fPIC -O2" ./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) CFLAGS="-fPIC -O2" install
cd ..

# ═══════════════════════════════════════════════════════════
# XZ
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ XZ ═══"
wget -q "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz"
tar -xf "xz-${XZ_VERSION}.tar.gz"
cd "xz-${XZ_VERSION}"
CFLAGS="-fPIC -O2" ./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) CFLAGS="-fPIC -O2" install
cd ..

# Xoá ARM binary khỏi DEPS_INSTALL/bin
for bin in xz xzdec lzma unlzma unxz lzcat lzma-config xz-config; do
    if [ -f "${DEPS_INSTALL}/bin/${bin}" ]; then
        if file "${DEPS_INSTALL}/bin/${bin}" 2>/dev/null | grep -q "ELF"; then
            rm -f "${DEPS_INSTALL}/bin/${bin}"
            echo "  🗑️  Removed ARM binary: ${bin}"
        fi
    fi
done

# ═══════════════════════════════════════════════════════════
# zlib — FORCE CLEAN BUILD với -fPIC
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ zlib ═══"
wget -q "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"
tar -xf "zlib-${ZLIB_VERSION}.tar.gz"
cd "zlib-${ZLIB_VERSION}"
# [FIX] Force clean build với -fPIC (bắt buộc cho static lib link vào .so)
make distclean 2>/dev/null || true
CFLAGS="-fPIC -O2" CC="${CC}" AR="${AR}" RANLIB="${RANLIB}" \
    ./configure --prefix="${DEPS_INSTALL}" --static
make clean 2>/dev/null || true
make -j$(nproc) CFLAGS="-fPIC -O2"
make install
cd ..

# ═══════════════════════════════════════════════════════════
# libxml2
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ libxml2 ═══"
wget -q "https://download.gnome.org/sources/libxml2/2.12/libxml2-${LIBXML2_VERSION}.tar.xz"
tar -xf "libxml2-${LIBXML2_VERSION}.tar.xz"
cd "libxml2-${LIBXML2_VERSION}"
CFLAGS="-fPIC -O2" ./configure ${COMMON_CONFIGURE_FLAGS} \
    --without-python --without-lzma --without-zlib --without-iconv --without-icu \
    LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) CFLAGS="-fPIC -O2" install
cd ..

if [ ! -f "${DEPS_INSTALL}/include/libxml2/libxml/xmlversion.h" ]; then
    echo "❌ libxml2 headers không tồn tại"
    exit 1
fi
if [ ! -x "${DEPS_INSTALL}/bin/xml2-config" ]; then
    echo "❌ xml2-config không tồn tại"
    exit 1
fi
echo "  ✅ libxml2 + xml2-config OK"

# ═══════════════════════════════════════════════════════════
# libxslt — chỉ build libxslt + libexslt (skip xsltproc)
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ libxslt (skip xsltproc) ═══"
wget -q "https://download.gnome.org/sources/libxslt/1.1/libxslt-${LIBXSLT_VERSION}.tar.xz"
tar -xf "libxslt-${LIBXSLT_VERSION}.tar.xz"
cd "libxslt-${LIBXSLT_VERSION}"

export CPPFLAGS="-I${DEPS_INSTALL}/include -I${DEPS_INSTALL}/include/libxml2 ${CPPFLAGS:-}"
export CFLAGS="-fPIC -O2 -I${DEPS_INSTALL}/include -I${DEPS_INSTALL}/include/libxml2 ${CFLAGS:-}"
export LDFLAGS="${COMMON_LDFLAGS} -L${DEPS_INSTALL}/lib"

OLD_PATH="${PATH}"
export PATH="${DEPS_INSTALL}/bin:${PATH}"
export XML_CONFIG="${DEPS_INSTALL}/bin/xml2-config"

./configure ${COMMON_CONFIGURE_FLAGS} \
    --without-python --without-crypto \
    --with-libxml-prefix="${DEPS_INSTALL}" \
    --with-libxml-include-prefix="${DEPS_INSTALL}/include/libxml2" \
    --with-libxml-libs-prefix="${DEPS_INSTALL}/lib" \
    XML_CONFIG="${DEPS_INSTALL}/bin/xml2-config" \
    CPPFLAGS="${CPPFLAGS}" \
    CFLAGS="${CFLAGS}" \
    LDFLAGS="${LDFLAGS}"

export PATH="${OLD_PATH}"
unset XML_CONFIG

make -j$(nproc) -C libxslt CFLAGS="${CFLAGS}"
make -j$(nproc) -C libexslt CFLAGS="${CFLAGS}"
make -C libxslt install
make -C libexslt install

[ -f xslt-config ] && install -m 755 xslt-config "${DEPS_INSTALL}/bin/xslt-config"
[ -f libxslt.pc ] && install -m 644 libxslt.pc "${DEPS_INSTALL}/lib/pkgconfig/"
[ -f libexslt.pc ] && install -m 644 libexslt.pc "${DEPS_INSTALL}/lib/pkgconfig/"

cd ..

for bin in xsltproc xslt-config; do
    if [ -f "${DEPS_INSTALL}/bin/${bin}" ]; then
        if file "${DEPS_INSTALL}/bin/${bin}" 2>/dev/null | grep -q "ELF"; then
            rm -f "${DEPS_INSTALL}/bin/${bin}"
        fi
    fi
done

if [ ! -f "${DEPS_INSTALL}/lib/libxslt.a" ] || [ ! -f "${DEPS_INSTALL}/lib/libexslt.a" ]; then
    echo "❌ libxslt.a hoặc libexslt.a không tồn tại"
    exit 1
fi
echo "  ✅ libxslt + libexslt OK"

# ═══════════════════════════════════════════════════════════
# libjpeg-turbo
# ═══════════════════════════════════════════════════════════
echo ""
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
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_TURBOJPEG=OFF -DWITH_SIMD=OFF ..
ninja && ninja install
cd ../..

# ═══════════════════════════════════════════════════════════
# libpng
# ═══════════════════════════════════════════════════════════
echo ""
echo "═══ libpng ═══"
wget -q "https://download.sourceforge.net/libpng/libpng-${LIBPNG_VERSION}.tar.gz" \
    || wget -q "https://github.com/pnggroup/libpng/archive/refs/tags/v${LIBPNG_VERSION}.tar.gz" -O "libpng-${LIBPNG_VERSION}.tar.gz"
tar -xf "libpng-${LIBPNG_VERSION}.tar.gz"
cd "libpng-${LIBPNG_VERSION}"
CFLAGS="-fPIC -O2" ./configure ${COMMON_CONFIGURE_FLAGS} LDFLAGS="${COMMON_LDFLAGS}"
make -j$(nproc) CFLAGS="-fPIC -O2" install
cd ..

# ═══════════════════════════════════════════════════════════
# OpenBLAS
# ═══════════════════════════════════════════════════════════
echo ""
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

# ═══════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "✅ Tất cả core deps built"
echo "════════════════════════════════════════════"

# Verify critical libs
MISSING=""
for lib in libffi.a libssl.so libcrypto.so libsqlite3.a liblzma.a libz.a \
           libxml2.a libxslt.a libexslt.a libjpeg.a libpng.a libopenblas.a; do
    [ ! -f "${DEPS_INSTALL}/lib/${lib}" ] && MISSING="$MISSING $lib"
done
if [ -n "$MISSING" ]; then
    echo "❌ MISSING LIBS: $MISSING"
    exit 1
fi
echo "✅ Tất cả critical libs có mặt"