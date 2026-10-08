#!/bin/bash
# Cross-compile CPython cho Android.
# Đọc source tarball từ ${PYTHON_SRC} (đã có sẵn trong Docker image).
set -eo pipefail

# [FIX] Tarball ở /opt/python-src (giữ từ Dockerfile)
TARBALL="${PYTHON_SRC:-/opt/python-src}/Python-${PYTHON_VERSION}.tar.xz"

# Fallback: tải lại nếu thiếu (khi chạy script ngoài Docker)
if [ ! -f "$TARBALL" ]; then
    echo "⚠️  Không có $TARBALL — tải lại"
    mkdir -p "$(dirname "$TARBALL")"
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
        -O "$TARBALL"
fi

echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

# Extract
cd /tmp
rm -rf "Python-${PYTHON_VERSION}"
tar -xf "$TARBALL"
cd "Python-${PYTHON_VERSION}"

printf '%s\n' '*disabled*' '_crypt' '_nis' 'spwd' 'ossaudiodev' \
    '_curses' '_curses_panel' 'readline' '_multiprocessing' 'nis' > Modules/Setup.local

# Force hash-style=both cho MỌI extension
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

# Patch Makefile để force flags
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
# Verify
# ============================================================
echo ""
echo "🔍 Verify DT_HASH + DT_GNU_HASH trên libpython..."
LP="${TARGET_ROOT}/lib/libpython${PYTHON_MINOR}.so"
if [ -f "$LP" ]; then
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l)
    GNU=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -c "GNU_HASH" || true)
    echo "  libpython${PYTHON_MINOR}.so: SysV=$SYSV GNU=$GNU"
    if [ "$SYSV" -eq 0 ]; then
        echo "❌ libpython thiếu DT_HASH"
        exit 1
    fi
else
    echo "❌ Không tìm thấy $LP"
    exit 1
fi

# Verify dynsym (PyLong_Type phải có)
if ! ${READELF} --dyn-syms "$LP" 2>/dev/null | grep -q " PyLong_Type$"; then
    echo "❌ libpython thiếu PyLong_Type"
    exit 1
fi
echo "✅ libpython${PYTHON_MINOR}.so có DT_HASH + PyLong_Type"

# Verify lib-dynload extensions
LIBDYLOAD="${TARGET_ROOT}/lib/python${PYTHON_MINOR}/lib-dynload"
if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Verify lib-dynload extensions..."
    FAIL=0
    COUNT=0
    for so in "$LIBDYLOAD"/*.so; do
        [ -f "$so" ] || continue
        COUNT=$((COUNT+1))
        SYSV=$(${READELF} --dynamic "$so" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l)
        GNU=$(${READELF} --dynamic "$so" 2>/dev/null | grep -c "GNU_HASH" || true)
        if [ "$SYSV" -eq 0 ] || [ "$GNU" -eq 0 ]; then
            echo "  ❌ $(basename "$so") — SysV=$SYSV GNU=$GNU"
            FAIL=$((FAIL+1))
        fi
    done

    echo "  Tổng: $COUNT extension, $FAIL lỗi"
    if [ "$FAIL" -gt 0 ]; then
        echo "❌ $FAIL extensions thiếu hash table"
        exit 1
    fi
    echo "✅ Tất cả extensions có DT_HASH + DT_GNU_HASH"
else
    echo "⚠️  Không có lib-dynload"
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"