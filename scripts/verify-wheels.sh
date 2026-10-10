#!/bin/bash
# Verify tất cả wheels là bionic + đúng chuẩn abi3
set -eo pipefail

GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
TAG_PAT='android_[0-9]+_[a-z0-9_]+'
ABI3_PAT='cp3[0-9]+-abi3-'
PYVER_PAT='libpython3\.[0-9]+\.so'
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

    IS_ABI3=0
    if [[ "$base" == *"-abi3-"* ]]; then
        if [[ "$base" =~ $ABI3_PAT ]]; then
            IS_ABI3=1
        else
            echo "❌ $base — abi3 tag sai format"
            FAIL=$((FAIL+1))
            continue
        fi
    fi

    work=$(mktemp -d)
    unzip -q -o "$whl" -d "$work"

    bad_glibc=0
    bad_abi3_libpython=0

    while IFS= read -r so; do
        [ -f "$so" ] || continue

        if ${READELF} -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
            echo "   ❌ $(basename "$so") link glibc:"
            ${READELF} -d "$so" | grep -E 'NEEDED' | grep -E "$GLIBC_PAT" | sed 's/^/      /'
            bad_glibc=1
        fi

        if [ "$IS_ABI3" -eq 1 ]; then
            if ${READELF} -d "$so" 2>/dev/null | grep -qE "NEEDED.*${PYVER_PAT}"; then
                echo "   ❌ $(basename "$so") abi3 wheel link libpython:"
                ${READELF} -d "$so" | grep -E "NEEDED.*${PYVER_PAT}" | sed 's/^/      /'
                bad_abi3_libpython=1
            fi
        fi
    done < <(find "$work" -name "*.so")

    rm -rf "$work"

    if [ "$bad_glibc" -eq 1 ]; then
        echo "❌ $base — link glibc"
        FAIL=$((FAIL+1))
    elif [ "$bad_abi3_libpython" -eq 1 ]; then
        echo "❌ $base — abi3 wheel link libpython (mất tính portable)"
        FAIL=$((FAIL+1))
    else
        if [ "$IS_ABI3" -eq 1 ]; then
            echo "✅ $base (abi3, portable)"
        else
            echo "✅ $base"
        fi
    fi
done

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "❌ $FAIL wheel(s) không hợp lệ"
    exit 1
fi
echo "✅ Tất cả wheel đều là Android bionic + abi3 đúng chuẩn"