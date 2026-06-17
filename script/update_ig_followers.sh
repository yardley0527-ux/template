#!/bin/bash
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ -f "$REPO_DIR/.env" ]; then
  export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

pip3 install -q -r requirements-ig.txt
python3 script/fetch_ig_followers.py

git add data/ig_followers_data.json
if ! git diff --staged --quiet; then
  git commit -m "📊 更新 IG 粉絲數 $(date +%Y-%m-%d)"
  git push origin main
  echo "Pushed to GitHub."
else
  echo "No changes to push."
fi
