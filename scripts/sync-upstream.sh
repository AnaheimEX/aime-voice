#!/bin/sh
# Merge origin/main into the local branch (docs/upstream-merge.md).
#   scripts/sync-upstream.sh            predict conflicts, merge, check the local seam
#   scripts/sync-upstream.sh --dry-run  predict conflicts only; nothing is changed
set -eu
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "sync-upstream: working tree is dirty; commit or stash local work first" >&2
  exit 1
fi

# Replays conflict resolutions already made once (repository-local setting).
git config rerere.enabled true
git fetch origin
if git merge-base --is-ancestor origin/main HEAD; then
  echo "sync-upstream: already contains origin/main"
  scripts/check-local-seam.sh
  exit 0
fi

echo "sync-upstream: upstream commits:"
git log --oneline HEAD..origin/main
python3 scripts/seam-hooks.py check-upstream origin/main
# Merge in memory first: shows the conflicting files without touching the work tree.
if git merge-tree --write-tree --name-only --no-messages HEAD origin/main >/dev/null; then
  echo "sync-upstream: no conflicts predicted"
else
  echo "sync-upstream: git merge-tree conflicts predicted in (seam-hooks will auto-resolve hook files):"
  git merge-tree --write-tree --name-only --no-messages HEAD origin/main | tail -n +2
fi
[ "${1:-}" = "--dry-run" ] && exit 0

if ! git merge --no-edit origin/main; then
  conflicted=$(git diff --name-only --diff-filter=U || true)
  if [ -n "$conflicted" ] && echo "$conflicted" | xargs python3 scripts/seam-hooks.py reapply-from MERGE_HEAD; then
    echo "$conflicted" | xargs git add --
    scripts/check-local-seam.sh
    git commit --no-edit
    echo "sync-upstream: hook conflicts auto-resolved by scripts/seam-hooks.py"
  else
    echo "sync-upstream: merge stopped with non-hook conflicts." >&2
    git diff --name-only --diff-filter=U >&2 || true
    exit 1
  fi
fi

scripts/check-local-seam.sh
echo "sync-upstream: origin/main merged; run scripts/check-local-seam.sh --build before the next local build"
