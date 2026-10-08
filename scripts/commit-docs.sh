#!/bin/bash
# Commit docs/ vào repo (dùng cho GitHub Pages)
set -eo pipefail

cd "${WORKSPACE}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Tạo docs/index.html redirect nếu thiếu
if [ ! -f "docs/index.html" ]; then
    cat > docs/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta http-equiv="refresh" content="0; url=./simple/">
  <title>Python Package Index</title>
</head>
<body>
  <h1>Python Package Index</h1>
  <p><a href="./simple/">simple index</a></p>
</body>
</html>
HTMLEOF
fi

git add docs/ 2>/dev/null || true
if git diff --staged --quiet; then
    echo "no change in docs/"
    exit 0
fi

git commit -m "chore(wheels): update index [skip ci]"

for i in 1 2 3; do
    if git pull --rebase origin "${REF_NAME}" && \
       git push origin "HEAD:${REF_NAME}"; then
        echo "✅ Pushed (attempt $i)"
        exit 0
    fi
    sleep 5
done

echo "❌ Push failed"
exit 1