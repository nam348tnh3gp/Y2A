#!/bin/bash
# Cross-compile CPython cho Android
set -eo pipefail

# ════════════════════════════════════════════════════════════
# Tarball fallback
# ════════════════════════════════════════════════════════════
TARBALL="/tmp/build-host/Python-${PYTHON_VERSION}.tar.xz"

if [ ! -f "$TARBALL" ] && [ -f "/opt/python-src/Python-${PYTHON_VERSION}.tar.xz" ]; then
    echo "  ℹ️  Copy tarball từ /opt/python-src"
    mkdir -p /tmp/build-host
    cp "/opt/python-src/Python-${PYTHON_VERSION}.tar.xz" "$TARBALL"
fi

if [ ! -f "$TARBALL" ]; then
    echo "  ⚠️  Không có $TARBALL — tải lại"
    mkdir -p /tmp/build-host
    cd /tmp/build-host
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
fi

echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

# ════════════════════════════════════════════════════════════
# Export env vars
# ════════════════════════════════════════════════════════════
export CFLAGS="-fPIC -O2 -I${DEPS_INSTALL}/include -Wno-implicit-function-declaration"
export CPPFLAGS="-I${DEPS_INSTALL}/include"
export LDFLAGS="-L${DEPS_INSTALL}/lib -Wl,--hash-style=both"

# ════════════════════════════════════════════════════════════
# Extract + setup
# ════════════════════════════════════════════════════════════
cd /tmp
rm -rf "/tmp/Python-${PYTHON_VERSION}"
tar -xf "$TARBALL"
cd "Python-${PYTHON_VERSION}"

# Disable modules không có trên Android
printf '%s\n' '*disabled*' '_crypt' '_nis' 'spwd' 'ossaudiodev' \
    '_curses' '_curses_panel' 'readline' '_multiprocessing' 'nis' \
    '_uuid' > Modules/Setup.local

export LDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"
export BLDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"
export CCSHARED="-fPIC -Wl,--hash-style=both"
export LDCXXSHARED="${CXX} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both"
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

sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^CCSHARED=.*|CCSHARED= -fPIC -Wl,--hash-style=both|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

make -j$(nproc) \
    LDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    BLDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    CCSHARED="-fPIC -Wl,--hash-style=both"
make install

# ════════════════════════════════════════════════════════════
# Verify hash tables
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify DT_HASH + DT_GNU_HASH trên libpython..."
LP="${TARGET_ROOT}/lib/libpython3.13.so"
if [ -f "$LP" ]; then
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l)
    GNU=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -c "GNU_HASH" || true)
    echo "  libpython3.13.so: SysV=$SYSV GNU=$GNU"
    if [ "$SYSV" -eq 0 ]; then
        echo "❌ libpython thiếu DT_HASH"
        exit 1
    fi
else
    echo "❌ Không tìm thấy $LP"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# [FIX] Verify PyLong_Type — dùng llvm-nm thay vì readelf
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify PyLong_Type trong .dynsym..."
LLVM_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
[ ! -x "$LLVM_NM" ] && LLVM_NM="llvm-nm"

NM_OUT=$("$LLVM_NM" -D "$LP" 2>/dev/null || true)

if echo "$NM_OUT" | grep -q "PyLong_Type"; then
    echo "  ✅ PyLong_Type present (llvm-nm)"
elif ${READELF} --dyn-syms "$LP" 2>/dev/null | grep -q "PyLong_Type"; then
    echo "  ✅ PyLong_Type present (llvm-readelf)"
else
    echo "  ❌ PyLong_Type MISSING"
    echo "  === Debug: dynsym total ==="
    echo "$NM_OUT" | wc -l
    echo "  === Debug: first 20 symbols ==="
    echo "$NM_OUT" | head -20
    exit 1
fi

# ════════════════════════════════════════════════════════════
# Verify critical extensions
# ════════════════════════════════════════════════════════════
LIBDYLOAD="${TARGET_ROOT}/lib/python3.13/lib-dynload"
if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Verify critical extensions..."
    CRITICAL="_lzma _sqlite3 _ssl _ctypes _hashlib _socket _posixsubprocess zlib binascii"
    for mod in $CRITICAL; do
        FOUND=$(ls "$LIBDYLOAD"/${mod}.*.so 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            echo "  ✅ $(basename "$FOUND")"
        else
            echo "  ⚠️  Thiếu: $mod"
        fi
    done
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"