#!/bin/bash
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ -f "$REPO_DIR/.env" ]; then
  export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

pip3 install -q -r requirements-ig.txt
python3 script/fetch_ig_followers.py

# 這份資料要進正式站（Render 只照 main 部署），跟你目前開發用的分支無關。
# 用獨立的 worktree 專門對 main 操作，不管現在人在哪個 feature branch 上，
# 都不會把未合併的開發內容一起帶去 main，也不會讓資料被卡在 feature branch 上出不去。
MAIN_WORKTREE="$REPO_DIR/.ig-data-main-worktree"
git fetch origin main

if [ ! -d "$MAIN_WORKTREE" ]; then
  git worktree add "$MAIN_WORKTREE" main
else
  git -C "$MAIN_WORKTREE" checkout main
  git -C "$MAIN_WORKTREE" reset --hard origin/main
fi

cp data/ig_followers_data.json "$MAIN_WORKTREE/data/ig_followers_data.json"
cd "$MAIN_WORKTREE"
git add data/ig_followers_data.json
if ! git diff --staged --quiet; then
  git commit -m "📊 更新 IG 粉絲數 $(date +%Y-%m-%d)"
  git push origin main
  echo "Pushed to GitHub (main)."
else
  echo "No changes to push."
fi
cd "$REPO_DIR"
