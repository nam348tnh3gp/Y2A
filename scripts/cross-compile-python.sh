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
# [FIX] Export PKG_CONFIG_PATH — CPython configure cần để
# detect sqlite3, openssl, libffi qua pkg-config
# ════════════════════════════════════════════════════════════
export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

echo "  PKG_CONFIG_PATH: $PKG_CONFIG_PATH"

# ════════════════════════════════════════════════════════════
# [FIX] Verify/Create sqlite3.pc
# ════════════════════════════════════════════════════════════
if [ ! -f "${DEPS_INSTALL}/lib/pkgconfig/sqlite3.pc" ]; then
    echo "  ⚠️  sqlite3.pc không tồn tại — tạo thủ công"
    mkdir -p "${DEPS_INSTALL}/lib/pkgconfig"
    cat > "${DEPS_INSTALL}/lib/pkgconfig/sqlite3.pc" <<EOF
prefix=${DEPS_INSTALL}
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: SQLite
Description: SQL database engine
Version: 3.46.1
Libs: -L\${libdir} -lsqlite3
Libs.private: -lm -ldl -lpthread
Cflags: -I\${includedir}
EOF
    echo "  ✅ Created: ${DEPS_INSTALL}/lib/pkgconfig/sqlite3.pc"
fi

echo "  sqlite3.pc content:"
cat "${DEPS_INSTALL}/lib/pkgconfig/sqlite3.pc" || true

# Verify sqlite3.pc detect được qua pkg-config
if command -v pkg-config >/dev/null 2>&1; then
    PC_CHECK=$(pkg-config --exists sqlite3 && echo "OK" || echo "FAIL")
    echo "  pkg-config --exists sqlite3: $PC_CHECK"
    pkg-config --cflags --libs sqlite3 || true
fi

# ════════════════════════════════════════════════════════════
# Export build env
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

# ════════════════════════════════════════════════════════════
# [FIX] Debug: check sqlite3 detection trong Makefile
# ════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "  Debug: sqlite3 detection"
echo "════════════════════════════════════════════"
grep -E "^MODULE__SQLITE3_" Makefile || echo "  (không có biến MODULE__SQLITE3_*)"
grep -E "^SQLITE3_" Makefile | head -10 || echo "  (không có SQLITE3_*)"

# ════════════════════════════════════════════════════════════
# [FIX] Force add _sqlite3 vào Setup.local nếu configure miss
# ════════════════════════════════════════════════════════════
# Kiểm tra `have_sqlite3`
if grep -q "^MODULE__SQLITE3_TRUE=" Makefile && ! grep -q "^MODULE__SQLITE3_TRUE=.*_sqlite3" Makefile; then
    # Nếu MODULE__SQLITE3_TRUE không có nội dung hoặc vẫn là '#'
    if grep -qE "^MODULE__SQLITE3_TRUE=\s*$" Makefile || grep -qE "^#_sqlite3" Modules/Setup.stdlib 2>/dev/null; then
        echo ""
        echo "  ⚠️  Configure không detect sqlite3 — force enable trong Setup.local"
        cat >> Modules/Setup.local <<EOF

# Force enable _sqlite3
_sqlite3 _sqlite/module.c _sqlite/connection.c _sqlite/cursor.c _sqlite/microprotocols.c _sqlite/prepare_protocol.c _sqlite/row.c _sqlite/statement.c _sqlite/util.c -I${DEPS_INSTALL}/include -L${DEPS_INSTALL}/lib -lsqlite3
EOF
        echo "  ✅ Đã thêm _sqlite3 vào Modules/Setup.local"
        echo "  Nội dung Setup.local:"
        cat Modules/Setup.local
    fi
fi

# ════════════════════════════════════════════════════════════
# Patch Makefile link flags
# ════════════════════════════════════════════════════════════
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
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l || true)
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
# Verify PyLong_Type
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify PyLong_Type trong .dynsym..."
LLVM_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
[ ! -x "$LLVM_NM" ] && LLVM_NM="llvm-nm"

NM_OUT=$("$LLVM_NM" -D "$LP" 2>/dev/null || true)
if echo "$NM_OUT" | grep -q "PyLong_Type"; then
    echo "  ✅ PyLong_Type present"
elif ${READELF} --dyn-syms "$LP" 2>/dev/null | grep -q "PyLong_Type"; then
    echo "  ✅ PyLong_Type present"
else
    echo "  ❌ PyLong_Type MISSING"
    exit 1
fi

# ════════════════════════════════════════════════════════════
# Verify critical extensions
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify critical extensions..."
LIBDYLOAD="${TARGET_ROOT}/lib/python3.13/lib-dynload"
if [ -d "$LIBDYLOAD" ]; then
    CRITICAL="_lzma _sqlite3 _ssl _ctypes _hashlib _socket _posixsubprocess zlib binascii"
    MISSING=""
    for mod in $CRITICAL; do
        FOUND=$(ls "$LIBDYLOAD"/${mod}.*.so 2>/dev/null | head -1 || true)
        if [ -n "$FOUND" ]; then
            echo "  ✅ $(basename "$FOUND")"
        else
            echo "  ⚠️  Thiếu: $mod"
            MISSING="$MISSING $mod"
        fi
    done
    if [ -n "$MISSING" ]; then
        echo "  ⚠️  Modules thiếu:$MISSING"
    fi
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"