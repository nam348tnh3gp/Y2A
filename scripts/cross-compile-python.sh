#!/bin/bash
# Cross-compile CPython cho Android.
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
# Linker flags — KHÔNG hash-style ở CCSHARED
# ============================================================
export LDSHARED="${CC} -shared -Wl,--hash-style=both"
export BLDSHARED="${CC} -shared -Wl,--hash-style=both"
export CCSHARED="-fPIC"
export LDCXXSHARED="${CXX} -shared -Wl,--hash-style=both"
export LINKFORSHARED="-Wl,--hash-style=both -Xlinker -export-dynamic"

# ============================================================
# Pre-configure env cho detect
# ============================================================
INCLUDE_FLAGS="-I${DEPS_INSTALL}/include -I${TARGET_ROOT}/include/python${PYTHON_MINOR}"
export CPPFLAGS="${INCLUDE_FLAGS}"
export CFLAGS="${INCLUDE_FLAGS} -fPIC"
export CXXFLAGS="${INCLUDE_FLAGS} -fPIC"
export LDFLAGS="-L${DEPS_INSTALL}/lib -Wl,--hash-style=both"

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
# [FIX] Patch Makefile — dump tất cả *FLAGS trước khi patch
# ============================================================
echo ""
echo "════════════════════════════════════════════"
echo "  Makefile: dump *FLAGS variables TRƯỚC patch"
echo "════════════════════════════════════════════"
grep -nE "^[A-Z_]*FLAGS\s*=" Makefile | head -40 || true

# ------------------------------------------------------------
# 1. Force linker flags
# ------------------------------------------------------------
sed -i "s|^LDSHARED=.*|LDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^BLDSHARED=.*|BLDSHARED= ${CC} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^LDCXXSHARED=.*|LDCXXSHARED= ${CXX} -shared -Wl,--hash-style=both|" Makefile
sed -i "s|^LINKFORSHARED=.*|LINKFORSHARED= -Wl,--hash-style=both -Xlinker -export-dynamic|" Makefile

# ------------------------------------------------------------
# 2. [FIX] Bỏ hash-style khỏi CCSHARED + CFLAGSFORSHARED
#    (tránh warning 'linker input unused' khi compile .c)
# ------------------------------------------------------------
for var in CCSHARED CFLAGSFORSHARED; do
    if grep -q "^${var}=" Makefile; then
        sed -i "s|^${var}=.*|${var}= -fPIC|" Makefile
        echo "✅ Fixed ${var} (removed hash-style)"
    fi
done

# ------------------------------------------------------------
# 3. [FIX] PREPEND -I${DEPS_INSTALL}/include vào MỌI biến flags
#    Dùng prepend (không replace) để không phá structure.
# ------------------------------------------------------------
PATCHED=0
for var in PY_CFLAGS PY_CFLAGS_NODIST PY_CPPFLAGS PY_CPPFLAGS_NODIST \
           BASECFLAGS OPT CFLAGS_NODIST CPPFLAGS_NODIST CONFIGURE_CFLAGS; do
    if grep -qE "^${var}\s*=" Makefile; then
        sed -i "s|^${var}\s*=|${var}= -I${DEPS_INSTALL}/include |" Makefile
        echo "✅ Prepended -I${DEPS_INSTALL}/include to ${var}"
        PATCHED=$((PATCHED+1))
    fi
done

if [ "$PATCHED" -eq 0 ]; then
    echo "❌ Không tìm thấy biến flags nào để patch!"
    echo "=== Full dump 100 dòng đầu có FLAGS ==="
    grep -nE "FLAGS" Makefile | head -60
    exit 1
fi

# ------------------------------------------------------------
# 4. [FIX] Cũng inject vào PY_CORE_CFLAGS nếu nó tồn tại
# ------------------------------------------------------------
if grep -qE "^PY_CORE_CFLAGS\s*=" Makefile; then
    # Prepend vào $(PY_CFLAGS) trong định nghĩa
    sed -i "s|^PY_CORE_CFLAGS\s*=.*|PY_CORE_CFLAGS= -I${DEPS_INSTALL}/include \$(PY_CFLAGS) \$(PY_CFLAGS_NODIST) \$(PY_CPPFLAGS) \$(CFLAGSFORSHARED)|" Makefile
    echo "✅ Patched PY_CORE_CFLAGS"
fi

# ------------------------------------------------------------
# 5. Verify
# ------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════"
echo "  Makefile: dump *FLAGS variables SAU patch"
echo "════════════════════════════════════════════"
grep -nE "^[A-Z_]*FLAGS\s*=" Makefile | head -40 || true

if ! grep -qE "${DEPS_INSTALL}/include" Makefile; then
    echo "❌ Patch không thành công — Makefile không chứa DEPS_INSTALL"
    exit 1
fi
echo ""
echo "✅ Makefile đã được patch với -I${DEPS_INSTALL}/include"

# ------------------------------------------------------------
# 6. Sanity check — dry compile 1 file để chắc chắn lzma.h tìm thấy
# ------------------------------------------------------------
echo ""
echo "🔍 Test compile _lzmamodule.c để verify"
TEST_CMD="make Modules/_lzmamodule.o -n 2>&1 | head -5"
echo "  → $TEST_CMD"
eval "$TEST_CMD" || true

# ============================================================
# Build
# ============================================================
echo ""
echo "════════════════════════════════════════════"
echo "  Building CPython"
echo "════════════════════════════════════════════"
make -j$(nproc)
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
echo "✅ libpython${PYTHON_MINOR}.so OK"

# ============================================================
# Verify critical extensions
# ============================================================
LIBDYLOAD="${TARGET_ROOT}/lib/python${PYTHON_MINOR}/lib-dynload"
if [ -d "$LIBDYLOAD" ]; then
    echo ""
    echo "🔍 Verify critical extensions..."
    CRITICAL="_lzma _sqlite3 _ssl _ctypes _hashlib _socket _posixsubprocess zlib binascii"
    MISSING=""
    for mod in $CRITICAL; do
        FOUND=$(ls "$LIBDYLOAD"/${mod}.*.so 2>/dev/null | head -1)
        if [ -n "$FOUND" ]; then
            echo "  ✅ $(basename "$FOUND")"
        else
            echo "  ⚠️  Thiếu: $mod"
            MISSING="$MISSING $mod"
        fi
    done
    [ -n "$MISSING" ] && echo "⚠️  Missing:$MISSING"
fi

echo ""
echo "✅ Cross-compile CPython hoàn tất"