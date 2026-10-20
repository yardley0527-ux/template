#!/bin/bash
set -e
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_DIR"

if [ -f "$REPO_DIR/.env" ]; then
  export $(grep -v '^#' "$REPO_DIR/.env" | xargs)
fi

# 用專屬的 Python 虛擬環境，不碰 Homebrew 的系統 Python：新版 Homebrew Python
# 不允許 pip 直接裝套件（externally-managed-environment），而且 brew 升級
# Python 版本時會把舊版本裝的套件一起帶走。壞掉時刪掉 .venv-ig 重跑即可重建。
VENV="$REPO_DIR/.venv-ig"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
"$VENV/bin/pip" install -q -r requirements-ig.txt
"$VENV/bin/python" script/fetch_ig_followers.py

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
