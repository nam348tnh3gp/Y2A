#!/bin/bash
# Build wheels trong container — p4a-style
# Xuất summary + failures ra file để workflow đọc
set -eo pipefail

HOST_PY="${HOST_PYTHON}"
WHEELS_OUT="${WHEELS_OUT}"
WORKSPACE="${WORKSPACE:-/work}"

mkdir -p "${WHEELS_OUT}"

SUMMARY_FILE="${WORKSPACE}/build-summary.txt"
SUMMARY_ENV="${WORKSPACE}/build-summary.env"
FAILURES_FILE="${WORKSPACE}/build-failures.txt"

SYSCONF_FILE=$(ls "${TARGET_STDLIB}"/_sysconfigdata__*.py 2>/dev/null | head -1 || true)
[ -z "$SYSCONF_FILE" ] && { echo "❌ Không có _sysconfigdata"; exit 1; }
SYSCONF_NAME=$(basename "$SYSCONF_FILE" .py)
SYSCONF_DIR="${WORKSPACE}/sysconfigdata-host"
rm -rf "$SYSCONF_DIR" && mkdir -p "$SYSCONF_DIR"
cp "$SYSCONF_FILE" "$SYSCONF_DIR/"

HOST_INCLUDE="${HOST_PY_PREFIX}/include/python${PYTHON_MINOR}"
mkdir -p "$HOST_INCLUDE"
TARGET_INCLUDE="${TARGET_ROOT}/include/python${PYTHON_MINOR}"
[ -d "$TARGET_INCLUDE" ] && cp -rf "$TARGET_INCLUDE/." "$HOST_INCLUDE/" 2>/dev/null || true

mkdir -p "${DEPS_INSTALL}/lib"
[ ! -f "${DEPS_INSTALL}/lib/librt.a" ] && ${AR} rcs "${DEPS_INSTALL}/lib/librt.a"

export _PYTHON_HOST_PLATFORM="${ANDROID_TAG}"
export _PYTHON_PROJECT_BASE="${TARGET_ROOT}"
export _PYTHON_SYSCONFIGDATA_NAME="${SYSCONF_NAME}"
export TARGET_PYTHON_EXE="${TARGET_ROOT}/bin/python${PYTHON_MINOR}"
export PYTHONPATH="${SYSCONF_DIR}:${TARGET_SITE}"
export PATH="${TARGET_SITE}/bin:${HOST_PY_PREFIX}/bin:${CARGO_HOME}/bin:${PATH}"

export CFLAGS="-fPIC -O2 \
    -I${NDK_SYSROOT}/usr/include \
    -I${NDK_SYSROOT}/usr/include/aarch64-linux-android \
    -I${CLANG_BUILTIN} \
    -I${DEPS_INSTALL}/include \
    -I${TARGET_ROOT}/include/python${PYTHON_MINOR} \
    -Wno-implicit-function-declaration"
export CPPFLAGS="$CFLAGS"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L${DEPS_INSTALL}/lib -L${NDK_SYSROOT}/usr/lib/aarch64-linux-android/${ANDROID_API}"

export PKG_CONFIG_PATH="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="${DEPS_INSTALL}/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR=""

export PYO3_PYTHON="${HOST_PY}"
export PYO3_CROSS=1
export PYO3_CROSS_PYTHON_VERSION="${PYTHON_MINOR}"
export PYO3_CROSS_LIB_DIR="${TARGET_ROOT}/lib"
export PYO3_CROSS_INCLUDE_DIR="${TARGET_ROOT}/include"

export CARGO_BUILD_TARGET="aarch64-linux-android"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="${CC}"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C link-arg=-L${DEPS_INSTALL}/lib"
export OPENSSL_DIR="${DEPS_INSTALL}"
export OPENSSL_LIB_DIR="${DEPS_INSTALL}/lib"
export OPENSSL_INCLUDE_DIR="${DEPS_INSTALL}/include"

SUCCESS=""
FAIL=""

# Reset summary files
> "$FAILURES_FILE"

for pkg in $PKGLIST; do
    echo ""
    echo "════════════════════════════════════════"
    echo "📦 $pkg"
    echo "════════════════════════════════════════"

    pkg_lower=$(echo "$pkg" | tr '[:upper:]' '[:lower:]')
    pkg_under=$(echo "$pkg_lower" | tr '-' '_')

    existing=$(ls -t "${WHEELS_OUT}"/${pkg_under}-*.whl \
                      "${WHEELS_OUT}"/${pkg_lower}-*.whl \
                      "${WHEELS_OUT}"/${pkg}-*.whl 2>/dev/null | head -1 || true)
    if [ -n "$existing" ]; then
        echo "⏭️  Đã có wheel: $(basename "$existing")"
        SUCCESS="$SUCCESS $pkg"
        continue
    fi

    BUILD_LOG="/tmp/build_${pkg}.log"

    if bash scripts/build-p4a-style.sh "$pkg" > "$BUILD_LOG" 2>&1; then
        whl=$(ls -t "${WHEELS_OUT}"/${pkg_under}-*.whl \
                     "${WHEELS_OUT}"/${pkg_lower}-*.whl \
                     "${WHEELS_OUT}"/${pkg}-*.whl 2>/dev/null | head -1 || true)
        if [ -n "$whl" ]; then
            echo "✅ $pkg — OK: $(basename "$whl")"
            SUCCESS="$SUCCESS $pkg"
        else
            echo "❌ $pkg — build OK nhưng không tìm thấy wheel"
            echo "=== $pkg ===" >> "$FAILURES_FILE"
            echo "Reason: build OK but no wheel found" >> "$FAILURES_FILE"
            echo "--- log (tail 30) ---" >> "$FAILURES_FILE"
            tail -30 "$BUILD_LOG" >> "$FAILURES_FILE"
            echo "" >> "$FAILURES_FILE"
            FAIL="$FAIL $pkg"
        fi
    else
        RC=$?
        echo "❌ $pkg — FAILED (rc=$RC)"
        echo "=== $pkg ===" >> "$FAILURES_FILE"
        echo "Reason: build-p4a-style.sh failed (rc=$RC)" >> "$FAILURES_FILE"
        echo "--- log (tail 40) ---" >> "$FAILURES_FILE"
        tail -40 "$BUILD_LOG" >> "$FAILURES_FILE"
        echo "" >> "$FAILURES_FILE"
        FAIL="$FAIL $pkg"

        # Vẫn show log ra stdout
        tail -30 "$BUILD_LOG" || true
    fi
done

# ════════════════════════════════════════════════════════════
# Write summary
# ════════════════════════════════════════════════════════════
SUCCESS=$(echo "$SUCCESS" | xargs)
FAIL=$(echo "$FAIL" | xargs)
SUCCESS_COUNT=$(echo "$SUCCESS" | wc -w)
FAIL_COUNT=$(echo "$FAIL" | wc -w)
WHEEL_COUNT=$(ls "${WHEELS_OUT}"/*.whl 2>/dev/null | wc -l)

if [ "$FAIL_COUNT" -eq 0 ]; then
    STATUS="SUCCESS"
elif [ "$WHEEL_COUNT" -gt 0 ]; then
    STATUS="PARTIAL"
else
    STATUS="FAILED"
fi

# Text summary — cho user đọc
cat > "$SUMMARY_FILE" <<EOF
════════════════════════════════════════════
BUILD SUMMARY — ${STATUS}
════════════════════════════════════════════
Total packages:  $((SUCCESS_COUNT + FAIL_COUNT))
✅ Success:      ${SUCCESS_COUNT}
❌ Failed:       ${FAIL_COUNT}
📦 Wheels:       ${WHEEL_COUNT}

✅ SUCCESS:
$(for p in $SUCCESS; do echo "  • $p"; done)
$([ -z "$SUCCESS" ] && echo "  (none)")

❌ FAILED:
$(for p in $FAIL; do echo "  • $p"; done)
$([ -z "$FAIL" ] && echo "  (none)")

Chi tiết lỗi xem file build-failures.txt
════════════════════════════════════════════
EOF

# ENV summary — cho workflow parse
cat > "$SUMMARY_ENV" <<EOF
BUILD_STATUS=${STATUS}
BUILD_SUCCESS_COUNT=${SUCCESS_COUNT}
BUILD_FAILED_COUNT=${FAIL_COUNT}
BUILD_WHEEL_COUNT=${WHEEL_COUNT}
BUILD_SUCCESS_PKGS=${SUCCESS}
BUILD_FAILED_PKGS=${FAIL}
EOF

echo ""
cat "$SUMMARY_FILE"

# Không exit 1 — để entrypoint tiếp tục
if [ -n "$FAIL" ]; then
    echo "⚠️  Có package fail:$FAIL"
    echo "   (sẽ tiếp tục xử lý phần OK)"
fi
exit 0