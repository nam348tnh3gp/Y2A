#!/bin/bash
# Cross-compile CPython cho Android — bản sao từ workflow cũ.
# Chỉ thêm fallback tải source nếu Docker không có sẵn.
set -eo pipefail

# ============================================================
# [ONLY NEW] Source tarball check
# ============================================================
TARBALL="/tmp/build-host/Python-${PYTHON_VERSION}.tar.xz"

# Nếu không có trong /tmp/build-host → thử /opt/python-src
if [ ! -f "$TARBALL" ] && [ -f "${PYTHON_SRC:-/opt/python-src}/Python-${PYTHON_VERSION}.tar.xz" ]; then
    mkdir -p /tmp/build-host
    cp "${PYTHON_SRC}/Python-${PYTHON_VERSION}.tar.xz" "$TARBALL"
fi

# Nếu vẫn không có → tải
if [ ! -f "$TARBALL" ]; then
    echo "⚠️  Không có $TARBALL — tải lại"
    mkdir -p /tmp/build-host
    cd /tmp/build-host
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
fi

echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

# ============================================================
# BẮT ĐẦU code cũ (giữ nguyên 100% từ workflow)
# ============================================================
cd /tmp
tar -xf "/tmp/build-host/Python-${PYTHON_VERSION}.tar.xz"
cd "Python-${PYTHON_VERSION}"

printf '%s\n' '*disabled*' '_crypt' '_nis' 'spwd' 'ossaudiodev' \
    '_curses' '_curses_panel' 'readline' '_multiprocessing' 'nis' > Modules/Setup.local

export LDSHARED="${CC} -shared -Wl,--hash-style=both"
export BLDSHARED="${CC} -shared -Wl,--hash-style=both"
export CCSHARED="-fPIC -Wl,--hash-style=both"
export LDCXXSHARED="${CXX} -shared -Wl,--hash-style=both"
export LINKFORSHARED="-Wl,--hash-style=both -Xlinker -export-dynamic"

LDFLAGS="-L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
OPENSSL_CFLAGS="-I${DEPS_INSTALL}/include" OPENSSL_LIBS="-L${DEPS_INSTALL}/lib -lssl -lcrypto" \
LIBFFI_CFLAGS="-I${DEPS_INSTALL}/include" LIBFFI_LIBS="-L${DEPS_INSTALL}/lib -lffi" \
SQLITE3_CFLAGS="-I${DEPS_INSTALL}/include" SQLITE3_LIBS="-L${DEPS_INSTALL}/lib -lsqlite3" \
LZMA_CFLAGS="-I${DEPS_INSTALL}/include" LZMA_LIBS="-L${DEPS_INSTALL}/lib -llzma" \
./configure \
    --host="${TARGET_HOST}" --build=x86_64-pc-linux-gnu \
    --prefix="${TARGET_ROOT}" \
    --with-build-python="${HOST_PYTHON}" \
    --enable-shared --disable-ipv6 --without-ensurepip \
    --with-openssl="${DEPS_INSTALL}" \
    ac_cv_file__dev_ptmx=no ac_cv_file__dev_ptc=no \
    ac_cv_buggy_getaddrinfo=no ac_cv_little_endian_double=yes

sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^CCSHARED=.*|CCSHARED= -fPIC -Wl,--hash-style=both|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

make -j$(nproc) \
    LDSHARED="${CC} -shared -Wl,--hash-style=both" \
    BLDSHARED="${CC} -shared -Wl,--hash-style=both" \
    CCSHARED="-fPIC -Wl,--hash-style=both"
make install

# ============================================================
# Verify (đã có trong code cũ — giữ nguyên)
# ============================================================
echo ""
echo "🔍 Verify DT_HASH..."
LP="${TARGET_ROOT}/lib/libpython${PYTHON_MINOR}.so"
if [ -f "$LP" ]; then
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l)
    GNU=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -c "GNU_HASH" || true)
    echo "  libpython${PYTHON_MINOR}.so: SysV=$SYSV GNU=$GNU"
    if [ "$SYSV" -eq 0 ]; then
        echo "❌ libpython thiếu DT_HASH"
        exit 1
    fi
fi

if ! ${READELF} --dyn-syms "$LP" 2>/dev/null | grep -q " PyLong_Type$"; then
    echo "❌ libpython thiếu PyLong_Type"
    exit 1
fi
echo "✅ libpython OK"

echo ""
echo "✅ Cross-compile CPython hoàn tất"