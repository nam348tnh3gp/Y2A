#!/bin/bash
# Cross-compile CPython cho Android — hỗ trợ mọi PYTHON_VERSION/PYTHON_MINOR
set -eo pipefail

echo "════════════════════════════════════════════"
echo "  Cross-compile CPython ${PYTHON_VERSION} (minor=${PYTHON_MINOR})"
echo "════════════════════════════════════════════"

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
    PY_URL="https://www.python.org/ftp/python/${PYTHON_VERSION}/Python-${PYTHON_VERSION}.tar.xz"
    if ! wget -q --spider "$PY_URL"; then
        echo "  ❌ Không tồn tại: $PY_URL"
        exit 1
    fi
    wget -q "$PY_URL"
fi

echo "✅ Source: $TARBALL ($(stat -c%s "$TARBALL") bytes)"

# ════════════════════════════════════════════════════════════
# Export PKG_CONFIG_PATH
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
# Setup.local — disable modules + force _sqlite3
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

_sqlite3 _sqlite/module.c _sqlite/connection.c _sqlite/cursor.c _sqlite/microprotocols.c _sqlite/prepare_protocol.c _sqlite/row.c _sqlite/statement.c _sqlite/util.c -I${DEPS_INSTALL}/include -L${DEPS_INSTALL}/lib -lsqlite3
EOF

echo ""
echo "════════════════════════════════════════════"
echo "  Modules/Setup.local"
echo "════════════════════════════════════════════"
cat Modules/Setup.local
echo "════════════════════════════════════════════"

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

echo ""
echo "  Debug: SQLITE3 detection"
grep -E "SQLITE3" Makefile | head -10 || echo "  (none)"

echo ""
echo "════════════════════════════════════════════"
echo "  Building CPython ${PYTHON_VERSION}"
echo "════════════════════════════════════════════"
make -j$(nproc) \
    LDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    BLDSHARED="${CC} -shared -L${DEPS_INSTALL}/lib -Wl,--hash-style=both" \
    CCSHARED="-fPIC -Wl,--hash-style=both"
make install

# ════════════════════════════════════════════════════════════
# Verify — dùng PYTHON_MINOR động
# ════════════════════════════════════════════════════════════
echo ""
echo "🔍 Verify libpython (minor=${PYTHON_MINOR})..."
LP="${TARGET_ROOT}/lib/libpython${PYTHON_MINOR}.so"
if [ -f "$LP" ]; then
    SYSV=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -E "\(HASH\)" | grep -v "GNU_HASH" | wc -l || true)
    GNU=$(${READELF} --dynamic "$LP" 2>/dev/null | grep -c "GNU_HASH" || true)
    echo "  libpython${PYTHON_MINOR}.so: SysV=$SYSV GNU=$GNU"
else
    echo "  ❌ KHÔNG có $LP"
    exit 1
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
LIBDYLOAD="${TARGET_ROOT}/lib/python${PYTHON_MINOR}/lib-dynload"
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
    [ -n "$MISSING" ] && echo "" && echo "  ⚠️  Modules thiếu:$MISSING (không fail)"
fi

if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Full content lib-dynload:"
    ls -1 "$LIBDYLOAD" | sort | head -60
fi

echo ""
echo "✅ Cross-compile CPython ${PYTHON_VERSION} hoàn tất"