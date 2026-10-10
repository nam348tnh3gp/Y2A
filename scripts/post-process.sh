#!/bin/bash
# Post-process: rename triplet tags → ANDROID_TAG, chỉ copy
set -eo pipefail

rm -rf "${WHEELS_FINAL}" && mkdir -p "${WHEELS_FINAL}"
shopt -s nullglob

COPIED=0; RENAMED=0; WARNED=0; ABI3_COUNT=0

for whl in "${WHEELS_OUT}"/*.whl; do
    [ -f "$whl" ] || continue
    base=$(basename "$whl")

    if [[ "$base" == *"none-any"* ]]; then
        cp "$whl" "${WHEELS_FINAL}/$base"
        COPIED=$((COPIED+1))
        echo "✅ $base (pure python)"
        continue
    fi

    if [[ "$base" == *"${ANDROID_TAG}"* ]]; then
        cp "$whl" "${WHEELS_FINAL}/$base"
        COPIED=$((COPIED+1))
        if [[ "$base" == *"-abi3-"* ]]; then
            ABI3_COUNT=$((ABI3_COUNT+1))
            echo "✅ $base (abi3)"
        else
            echo "✅ $base"
        fi
        continue
    fi

    newname="$base"
    newname="${newname//aarch64_linux_android/${ANDROID_TAG}}"
    newname="${newname//aarch64-linux-android/${ANDROID_TAG}}"
    newname="${newname//linux_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux_2_28_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux2014_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux_2_17_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux_2_24_aarch64/${ANDROID_TAG}}"

    # ═══ [ABI3] Normalize tag abi3 (chỉ nâng, không hạ) ═══
    if [[ "$newname" == *"-abi3-"* ]] && [ -n "${ABI3_TARGET:-}" ]; then
        cur_num=$(echo "$newname" | sed -nE 's/.*-cp3([0-9]+)-abi3-.*/\1/p')
        tgt_num="${ABI3_TARGET#cp3}"
        if [ -n "$cur_num" ] && [ -n "$tgt_num" ] && [ "$cur_num" -le "$tgt_num" ]; then
            newname=$(echo "$newname" | sed -E "s/cp3[0-9]+-abi3-/${ABI3_TARGET}-abi3-/")
        fi
    fi

    if [ "$newname" != "$base" ]; then
        cp "$whl" "${WHEELS_FINAL}/$newname"
        RENAMED=$((RENAMED+1))
        if [[ "$newname" == *"-abi3-"* ]]; then
            ABI3_COUNT=$((ABI3_COUNT+1))
            echo "🔄 $base → $newname (abi3)"
        else
            echo "🔄 $base → $newname"
        fi
    else
        echo "⚠️  $base — không nhận diện được, giữ nguyên"
        cp "$whl" "${WHEELS_FINAL}/$base"
        WARNED=$((WARNED+1))
    fi
done

echo ""
echo "Copied: $COPIED / Renamed: $RENAMED / Warned: $WARNED / ABI3: $ABI3_COUNT"
ls -lh "${WHEELS_FINAL}/" || true