#!/bin/sh
# Pull and merge origin/main. Voice module files are local and are not edited here.
set -eu
cd "$(dirname "$0")/.."

if [ -n "$(git status --porcelain)" ]; then
  echo "sync-upstream: working tree is dirty; commit or stash local work first" >&2
  exit 1
fi

git fetch origin
if ! git merge --no-edit origin/main; then
  echo "sync-upstream: merge stopped." >&2
  echo "Keep local voice paths unchanged. For every other conflict, take upstream and restore the calls in docs/upstream-merge.md." >&2
  git diff --name-only --diff-filter=U >&2 || true
  exit 1
fi

scripts/check-voice-seam.sh
echo "sync-upstream: origin/main merged; voice module left untouched"
