#!/bin/bash
# Verify tất cả wheels là bionic + có tag đúng
set -eo pipefail

GLIBC_PAT='libc\.so\.6|ld-linux|libm\.so\.6|libpthread\.so\.0'
TAG_PAT='android_[0-9]+_[a-z0-9_]+'
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

    work=$(mktemp -d)
    unzip -q -o "$whl" -d "$work"
    bad=0
    while IFS= read -r so; do
        if ${READELF} -d "$so" 2>/dev/null | grep -Eq "$GLIBC_PAT"; then
            echo "   ❌ $(basename "$so"):"
            ${READELF} -d "$so" | grep -E 'NEEDED' | grep -E "$GLIBC_PAT" | sed 's/^/      /'
            bad=1
        fi
    done < <(find "$work" -name "*.so")
    rm -rf "$work"

    if [ "$bad" -eq 0 ]; then
        echo "✅ $base"
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