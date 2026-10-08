#!/bin/bash
# Cross-compile CPython cho Android.
# Đọc source tarball từ ${PYTHON_SRC} (đã có trong Docker image).
set -eo pipefail

TARBALL="${PYTHON_SRC:-/opt/python-src}/Python-${PYTHON_VERSION}.tar.xz"
if [ ! -f "$TARBALL" ]; then
    echo "⚠️  Không có $TARBALL — tải lại"
    mkdir -p "$(dirname "$TARBALL")"
    wget -q "https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz" \
        -O "$TARBALL"
fi
echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

cd /tmp
rm -rf "Python-${PYTHON_VERSION}"
tar -xf "$TARBALL"
cd "Python-${PYTHON_VERSION}"

printf '%s\n' '*disabled*' '_crypt' '_nis' 'spwd' 'ossaudiodev' \
    '_curses' '_curses_panel' 'readline' '_multiprocessing' 'nis' > Modules/Setup.local

# ============================================================
# CC-related flags — KHÔNG có hash-style ở CCSHARED
# ============================================================
export LDSHARED="${CC} -shared -Wl,--hash-style=both"
export BLDSHARED="${CC} -shared -Wl,--hash-style=both"
export CCSHARED="-fPIC"                                    # [FIX] bỏ hash-style
export LDCXXSHARED="${CXX} -shared -Wl,--hash-style=both"
export LINKFORSHARED="-Wl,--hash-style=both -Xlinker -export-dynamic"

# ============================================================
# Pre-configure env cho detect (dùng CFLAGS sạch — không hash-style)
# ============================================================
INCLUDE_FLAGS="-I${DEPS_INSTALL}/include -I${TARGET_ROOT}/include/python${PYTHON_MINOR}"
export CPPFLAGS="${INCLUDE_FLAGS}"
export CFLAGS="${INCLUDE_FLAGS} -fPIC"
export CXXFLAGS="${INCLUDE_FLAGS} -fPIC"
export LDFLAGS="-L${DEPS_INSTALL}/lib -Wl,--hash-style=both"

# Module-specific
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

echo ""
echo "════════════════════════════════════════════"
echo "  Configure CPython"
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
# Patch Makefile — ĐÂY LÀ ĐIỂM MẤU CHỐT
# ============================================================

# 1. Force linker flags
sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^CCSHARED=.*|CCSHARED= -fPIC|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

# 2. [FIX] Inject -I${DEPS_INSTALL}/include vào PY_CFLAGS / PY_CPPFLAGS / PY_CORE_CFLAGS
#    Đây là biến CPython dùng để compile MỌI extension
DEPS_INC="\$(srcdir)/Include -I\$(srcdir)/Include/internal -I\$(srcdir)/Include/internal/mimalloc -I\$(srcdir) -I\$(srcdir)/Include"

echo "=== Makefile: PY_CFLAGS trước khi patch ==="
grep -E "^PY_CFLAGS=" Makefile || true
grep -E "^PY_CPPFLAGS=" Makefile || true
grep -E "^PY_CORE_CFLAGS=" Makefile || true

# Replace toàn bộ dòng
sed -i "s|^PY_CFLAGS=.*|PY_CFLAGS= ${INCLUDE_FLAGS} -fPIC ${DEPS_INC}|" Makefile
sed -i "s|^PY_CPPFLAGS=.*|PY_CPPFLAGS= ${INCLUDE_FLAGS}|" Makefile
sed -i "s|^PY_CORE_CFLAGS=.*|PY_CORE_CFLAGS= \$(PY_CFLAGS) \$(PY_CFLAGS_NODIST) \$(PY_CPPFLAGS) \$(CFLAGSFORSHARED)|" Makefile

echo "=== Makefile: PY_CFLAGS sau khi patch ==="
grep -E "^PY_CFLAGS=" Makefile
grep -E "^PY_CPPFLAGS=" Makefile
grep -E "^PY_CORE_CFLAGS=" Makefile

# Verify chứa DEPS_INSTALL
if ! grep -q "PY_CFLAGS=.*${DEPS_INSTALL}" Makefile; then
    echo "❌ Không inject được DEPS_INSTALL vào PY_CFLAGS"
    exit 1
fi
echo "✅ PY_CFLAGS có ${DEPS_INSTALL}/include"

# ============================================================
# Build
# ============================================================
make -j$(nproc) \
    LDSHARED="${CC} -shared -Wl,--hash-style=both" \
    BLDSHARED="${CC} -shared -Wl,--hash-style=both" \
    CCSHARED="-fPIC"
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

if ! ${READELF} --dyn-syms "$LP" 2>/dev/null | grep -q " PyLong_Type$"; then
    echo "❌ libpython thiếu PyLong_Type"
    exit 1
fi
echo "✅ libpython${PYTHON_MINOR}.so có DT_HASH + PyLong_Type"

# ============================================================
# Verify critical extensions
# ============================================================
LIBDYLOAD="${TARGET_ROOT}/lib/python${PYTHON_MINOR}/lib-dynload"
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
    [ "$FAIL" -gt 0 ] && exit 1
    echo "✅ Tất cả extensions có DT_HASH + DT_GNU_HASH"
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"