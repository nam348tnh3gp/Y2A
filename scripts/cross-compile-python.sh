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
# Export PKG_CONFIG_PATH — CPython configure cần
# ════════════════════════════════════════════════════════════
export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

echo "  PKG_CONFIG_PATH: $PKG_CONFIG_PATH"

# ════════════════════════════════════════════════════════════
# Tạo sqlite3.pc nếu thiếu
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

# ════════════════════════════════════════════════════════════
# [FIX] Ghi Setup.local — disable modules không cần +
# FORCE ADD các module critical (không phụ thuộc configure detect)
# ════════════════════════════════════════════════════════════
cat > Modules/Setup.local <<EOF
*disabled*
_crypt
_nis
spwd
ossaudiodev
_curses
_curses_panel
readline
_multiprocessing
nis
_uuid

# Force enable _sqlite3 (bỏ qua configure detection)
_sqlite3 _sqlite/module.c _sqlite/connection.c _sqlite/cursor.c _sqlite/microprotocols.c _sqlite/prepare_protocol.c _sqlite/row.c _sqlite/statement.c _sqlite/util.c -I${DEPS_INSTALL}/include -L${DEPS_INSTALL}/lib -lsqlite3
EOF

echo ""
echo "════════════════════════════════════════════"
echo "  Modules/Setup.local content:"
echo "════════════════════════════════════════════"
cat Modules/Setup.local
echo "════════════════════════════════════════════"

# Linker flags
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

# Patch Makefile
sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^CCSHARED=.*|CCSHARED= -fPIC -Wl,--hash-style=both|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

# ════════════════════════════════════════════════════════════
# Debug: xem CPython có nhận module không
# ════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "  Debug: sqlite3 detection trong Makefile"
echo "════════════════════════════════════════════"
grep -E "SQLITE3" Makefile | head -20 || echo "  (không có SQLITE3)"

echo ""
echo "════════════════════════════════════════════"
echo "  Debug: Makefile modules targets"
echo "════════════════════════════════════════════"
grep -E "_sqlite3" Makefile | head -20 || echo "  (không có _sqlite3 target)"

# ════════════════════════════════════════════════════════════
# Build
# ════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════"
echo "  Building CPython"
echo "════════════════════════════════════════════"
make -j$(nproc) \
    LDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    BLDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    CCSHARED="-fPIC -Wl,--hash-style=both"
make install

# ════════════════════════════════════════════════════════════
# Verify (non-fatal)
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify libpython..."
LP="${TARGET_ROOT}/lib/libpython3.13.so"
if [ -f "$LP" ]; then
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l || true)
    GNU=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -c "GNU_HASH" || true)
    echo "  libpython3.13.so: SysV=$SYSV GNU=$GNU"
fi

LLVM_NM="${NDK_TOOLCHAIN}/bin/llvm-nm"
[ ! -x "$LLVM_NM" ] && LLVM_NM="llvm-nm"
NM_OUT=$("$LLVM_NM" -D "$LP" 2>/dev/null || true)
if echo "$NM_OUT" | grep -q "PyLong_Type"; then
    echo "  ✅ PyLong_Type present"
else
    echo "  ❌ PyLong_Type MISSING"
fi

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
        echo ""
        echo "  ⚠️  Modules thiếu:$MISSING"
        echo "  (không fail — pipeline tiếp tục)"
    fi
fi

# ════════════════════════════════════════════════════════════
# Dump toàn bộ lib-dynload nếu thiếu module
# ════════════════════════════════════════════════════════════
if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Full content lib-dynload:"
    ls -1 "$LIBDYLOAD" | sort | head -60
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"