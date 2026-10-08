#!/bin/bash
# Tạo GitHub release với wheels
set -eo pipefail

if [ -z "${GH_TOKEN}" ]; then
    echo "⚠️  Không có GH_TOKEN"
    exit 0
fi

shopt -s nullglob
WHLS=("${WHEELS_FINAL}"/*.whl)
if [ ${#WHLS[@]} -eq 0 ]; then
    echo "⚠️  Không có wheel để release"
    exit 0
fi

# Cleanup nếu yêu cầu
if [ "${INPUT_CLEAN_OLD}" = "true" ]; then
    echo "=== Cleanup old releases ==="
    gh release list --limit 100 --json tagName \
        -q '.[] | select(.tagName | startswith("wheels-")) | .tagName' > /tmp/tags.txt || true
    TOTAL=$(wc -l < /tmp/tags.txt)
    if [ "$TOTAL" -gt 3 ]; then
        DELETE=$(tail -n +4 /tmp/tags.txt)
        while read -r tag; do
            [ -z "$tag" ] && continue
            echo "→ Xóa $tag"
            gh release delete "$tag" --yes --cleanup-tag 2>&1 || true
        done <<< "$DELETE"
    fi
fi

TAG="wheels-$(date +%Y%m%d-%H%M%S)"
echo "TAG=${TAG}" > /tmp/release_tag.env
echo "→ Creating release: $TAG"

gh release create "$TAG" \
    --title "Wheels $TAG" \
    --notes "Android aarch64 / Python ${PYTHON_MINOR}" \
    "${WHLS[@]}"

echo "✅ Release created: $TAG"