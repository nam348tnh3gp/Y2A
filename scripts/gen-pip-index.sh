#!/bin/bash
# Sinh pip index (PEP 503)
set -eo pipefail

source /tmp/release_tag.env
TAG="${TAG:?}"

python3 "${WORKSPACE}/scripts/gen_index.py" \
    "${WHEELS_FINAL}" \
    "${WORKSPACE}/docs" \
    "${GITHUB_REPO_OWNER:-nam348tnh3gp}" \
    "${GITHUB_REPO_NAME:-Y2A}" \
    "$TAG"

echo "✅ Pip index generated"