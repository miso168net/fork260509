#!/usr/bin/env bash
# Claude Code SessionStart hook — 自動執行 CLAUDE.md §6.4 / §9.7 的 SOP
# stdout 會被 Claude Code harness 以 additional context 注入到 session 第一輪
# 修改本檔不需重啟 CLI，下次新 session 就生效

set -u

cd "$(dirname "$0")/.."

echo "=== git status ==="
git status

echo
echo "=== git submodule status ==="
echo "(行首空格 = clean / + = SHA 不一致 / - = 未 init)"
git submodule status

echo
echo "=== worktree .git（應為檔案 = worktree 模式正確）==="
ls -la admin-web/.git admin-api/.git 2>&1

echo
echo "=== 最近 5 個外層 commit ==="
git log --oneline -5

echo
echo "=== docs/INTEGRATION-CHECKLIST.md（進度追蹤）==="
cat docs/INTEGRATION-CHECKLIST.md
