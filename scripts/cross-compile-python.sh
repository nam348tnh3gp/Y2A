#!/bin/bash
# Cross-compile CPython cho Android.
# Đọc source tarball từ ${PYTHON_SRC} (đã có sẵn trong Docker image).
set -eo pipefail

# Tarball ở /opt/python-src
TARBALL="${PYTHON_SRC:-/opt/python-src}/Python-${PYTHON_VERSION}.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "⚠️  Không có $TARBALL — tải lại"
    mkdir -p "$(dirname "$TARBALL")"
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
        -o "$TARBALL"
fi
echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

cd /tmp
rm -rf "Python-${PYTHON_VERSION}"
tar -xf "$TARBALL"
cd "Python-${PYTHON_VERSION}"

printf '%s\n' '*disabled*' '_crypt' '_nis' 'spwd' 'ossaudiodev' \
    '_curses' '_curses_panel' 'readline' '_multiprocessing' 'nis' > Modules/Setup.local

# ============================================================
# Force hash-style=both cho MỌI extension
# ============================================================
export LDSHARED="${CC} -shared -Wl,--hash-style=both"
export BLDSHARED="${CC} -shared -Wl,--hash-style=both"
export CCSHARED="-fPIC -Wl,--hash-style=both"
export LDCXXSHARED="${CXX} -shared -Wl,--hash-style=both"
export LINKFORSHARED="-Wl,--hash-style=both -Xlinker -export-dynamic"

# ============================================================
# [FIX] Export global CPPFLAGS/CFLAGS chứa include path của deps
# để mọi extension (lzma, sqlite3, ssl, ffi, zlib...) tìm thấy header
# ============================================================
export CPPFLAGS="-I${DEPS_INSTALL}/include -I${TARGET_ROOT}/include/python${PYTHON_MINOR} ${CPPFLAGS:-}"
export CFLAGS="${CPPFLAGS}"
export CXXFLAGS="${CPPFLAGS}"

# Biến riêng cho từng module — CPython dùng để detect
export OPENSSL_CFLAGS="-I${DEPS_INSTALL}/include"
export OPENSSL_LIBS="-L${DEPS_INSTALL}/lib -lssl -lcrypto"
export LIBFFI_CFLAGS="-I${DEPS_INSTALL}/include"
export LIBFFI_LIBS="-L${DEPS_INSTALL}/lib -lffi"
export SQLITE3_CFLAGS="-I${DEPS_INSTALL}/include"
export SQLITE3_LIBS="-L${DEPS_INSTALL}/lib -lsqlite3"
export LZMA_CFLAGS="-I${DEPS_INSTALL}/include"
export LZMA_LIBS="-L${DEPS_INSTALL}/lib -llzma"
export ZLIB_CFLAGS="-I${DEPS_INSTALL}/include"
export ZLIB_LIBS="-L${DEPS_INSTALL}/lib -lz"
export BZIP2_CFLAGS="-I${DEPS_INSTALL}/include"
export BZIP2_LIBS="-L${DEPS_INSTALL}/lib -lbz2"

# Link flags
export LDFLAGS="-L${DEPS_INSTALL}/lib -Wl,--hash-style=both"

echo ""
echo "════════════════════════════════════════════"
echo "  Configure CPython cross-compile"
echo "  CPPFLAGS: $CPPFLAGS"
echo "  LDFLAGS:  $LDFLAGS"
echo "════════════════════════════════════════════"

./configure \
    --host="${TARGET_HOST}" --build=x86_64-pc-linux-gnu \
    --prefix="${TARGET_ROOT}" \
    --with-build-python="${HOST_PYTHON}" \
    --enable-shared --disable-ipv6 --without-ensurepip \
    --with-openssl="${DEPS_INSTALL}" \
    ac_cv_file__dev_ptmx=no ac_cv_file__dev_ptc=no \
    ac_cv_buggy_getaddrinfo=no ac_cv_little_endian_double=yes

# ============================================================
# Patch Makefile để force linker flags
# ============================================================
sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^CCSHARED=.*|CCSHARED= -fPIC -Wl,--hash-style=both|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

# Verify Makefile giữ CPPFLAGS của chúng ta
if ! grep -q "DEPS_INSTALL" Makefile 2>/dev/null && ! grep -q "${DEPS_INSTALL}" Makefile 2>/dev/null; then
    echo "⚠️  Makefile không chứa DEPS_INSTALL — inject thủ công"
    sed -i "s|^PY_CFLAGS=.*|PY_CFLAGS= -I\$(srcdir)/Include/internal -I\$(srcdir)/Include -I${DEPS_INSTALL}/include|" Makefile
    sed -i "s|^PY_CPPFLAGS=.*|PY_CPPFLAGS= -I${DEPS_INSTALL}/include|" Makefile
fi

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

# Verify critical extensions
LIBDYLOAD="${TARGET_ROOT}/lib/python${PYTHON_MINOR}/lib-dynload"
if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Verify critical extensions..."
    CRITICAL="_lzma _sqlite3 _ssl _ctypes _hashlib _socket _posixsubprocess zlib"
    MISSING=""
    for mod in $CRITICAL; do
        FOUND=$(ls "$LIBDYLOAD"/${mod}.*.so 2>/dev/null | head -1)
        if [ -z "$FOUND" ]; then
            echo "  ⚠️  Không có module: $mod"
            MISSING="$MISSING $mod"
        else
            echo "  ✅ $mod"
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "⚠️  Một số module bị thiếu:$MISSING"
        # Không fail — có thể package không cần
    fi

    echo ""
    echo "🔍 Verify DT_HASH cho tất cả extensions..."
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