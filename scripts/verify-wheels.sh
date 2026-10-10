#!/bin/bash
# Verify tất cả wheels là bionic + có tag đúng
set -eo pipefail

GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
TAG_PAT='android_[0-9]+_[a-z0-9_]+'
ABI3_PAT='cp3[0-9]+-abi3-'
FAIL=0

for whl in "${WHEELS_FINAL}"/*.whl; do
    [ -f "$whl" ] || continue
    base=$(basename "$whl")

    if [[ "$base" == *"none-any"* ]]; then
        echo "⏭️  $base (pure python)"
        continue
    fi

    if ! [[ "$base" =~ $TAG_PAT ]]; then
        echo "❌ $base — tag không phải Android"
        FAIL=$((FAIL+1))
        continue
    fi

    # ═══ [ABI3] Kiểm tra tag abi3 hợp lệ ═══
    IS_ABI3=0
    if [[ "$base" == *"-abi3-"* ]]; then
        if [[ "$base" =~ $ABI3_PAT ]]; then
            IS_ABI3=1
        else
            echo "⚠️  $base — abi3 tag sai format (mong đợi cp3X-abi3-)"
        fi
    fi

    work=$(mktemp -d)
    unzip -q -o "$whl" -d "$work"
    bad=0
    while IFS= read -r so; do
        if ${READELF} -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
            echo "   ❌ $(basename "$so"):"
            ${READELF} -d "$so" | grep -E 'NEEDED' | grep -E "$GLIBC_PAT" | sed 's/^/      /'
            bad=1
        fi
        # ═══ [ABI3] Wheel abi3 không được NEEDED libpythonX.Y.so ═══
        if [ "$IS_ABI3" -eq 1 ]; then
            if ${READELF} -d "$so" 2>/dev/null | grep -qE 'NEEDED.*libpython3\.[0-9]+\.so'; then
                echo "   ⚠️  $(basename "$so"): abi3 wheel link libpython (không portable)"
                ${READELF} -d "$so" | grep -E 'NEEDED.*libpython' | sed 's/^/      /'
                # Cảnh báo, không fail cứng — một số crate vẫn NEEDED libpython
            fi
        fi
    done < <(find "$work" -name "*.so")
    rm -rf "$work"

    if [ "$bad" -eq 0 ]; then
        if [ "$IS_ABI3" -eq 1 ]; then
            echo "✅ $base (abi3)"
        else
            echo "✅ $base"
        fi
    else
        echo "❌ $base — link glibc"
        FAIL=$((FAIL+1))
    fi
done

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "❌ $FAIL wheel(s) không hợp lệ"
    exit 1
fi
echo "✅ Tất cả wheel đều là Android bionic"