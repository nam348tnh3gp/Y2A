#!/bin/bash
# Post-process: rename triplet tags → ANDROID_TAG, chỉ copy
set -eo pipefail

rm -rf "${WHEELS_FINAL}" && mkdir -p "${WHEELS_FINAL}"
shopt -s nullglob

COPIED=0; RENAMED=0; WARNED=0

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
        echo "✅ $base"
        continue
    fi

    newname="$base"
    newname="${newname//aarch64_linux_android/${ANDROID_TAG}}"
    newname="${newname//aarch64-linux-android/${ANDROID_TAG}}"
    newname="${newname//linux_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux_2_28_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux2014_aarch64/${ANDROID_TAG}}"
    newname="${newname//manylinux_2_17_aarch64/${ANDROID_TAG}}"

    if [ "$newname" != "$base" ]; then
        cp "$whl" "${WHEELS_FINAL}/$newname"
        RENAMED=$((RENAMED+1))
        echo "🔄 $base → $newname"
    else
        echo "⚠️  $base — không nhận diện được, giữ nguyên"
        cp "$whl" "${WHEELS_FINAL}/$base"
        WARNED=$((WARNED+1))
    fi
done

echo ""
echo "Copied: $COPIED / Renamed: $RENAMED / Warned: $WARNED"
ls -lh "${WHEELS_FINAL}/" || true