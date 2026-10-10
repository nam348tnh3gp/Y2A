#!/bin/bash
# Verify tất cả wheels là bionic (Android) — không còn abi3
set -eo pipefail

GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
TAG_PAT='android_[0-9]+_[a-z0-9_]+'
FAIL=0

shopt -s nullglob
WHEELS=("${WHEELS_FINAL}"/*.whl)
if [ ${#WHEELS[@]} -eq 0 ]; then
    echo "⚠️  Không có wheel nào trong ${WHEELS_FINAL}"
    exit 0
fi

for whl in "${WHEELS[@]}"; do
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

    work=$(mktemp -d)
    unzip -q -o "$whl" -d "$work"

    bad_glibc=0
    while IFS= read -r so; do
        [ -f "$so" ] || continue
        if ${READELF} -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
            echo "   ❌ $(basename "$so") link glibc:"
            ${READELF} -d "$so" | grep -E 'NEEDED' | grep -E "$GLIBC_PAT" | sed 's/^/      /'
            bad_glibc=1
        fi
    done < <(find "$work" -name "*.so")

    rm -rf "$work"

    if [ "$bad_glibc" -eq 1 ]; then
        echo "❌ $base — link glibc"
        FAIL=$((FAIL+1))
    else
        echo "✅ $base"
    fi
done

if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "❌ $FAIL wheel(s) không hợp lệ"
    exit 1
fi
echo "✅ Tất cả wheel đều là Android bionic"