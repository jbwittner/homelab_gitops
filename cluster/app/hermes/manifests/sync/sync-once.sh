#!/bin/sh
set -eu

SOURCE_DIR=/opt/data
WORK_DIR=/sync-work/repo
BRANCH=main
REMOTE_URL=https://forgejo.wittner.tech/jbwittner/homelab_hermes.git

export GIT_ASKPASS=/sync/git-askpass.sh
export GIT_TERMINAL_PROMPT=0
# Git operates only on a sidecar-private clone. Do not load host configuration or run hooks while
# this process has a Forgejo token; Hermes can write SOURCE_DIR but cannot write WORK_DIR.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null

if [ ! -d "$WORK_DIR/.git" ]; then
  mkdir -p "$(dirname "$WORK_DIR")"
  if git ls-remote --exit-code --heads "$REMOTE_URL" "$BRANCH" >/dev/null 2>&1; then
    git clone --branch "$BRANCH" --single-branch "$REMOTE_URL" "$WORK_DIR"
  else
    git init --initial-branch "$BRANCH" "$WORK_DIR"
    git -C "$WORK_DIR" remote add origin "$REMOTE_URL"
  fi
fi

cd "$WORK_DIR"
test "$(git branch --show-current)" = "$BRANCH"
test "$(git remote get-url origin)" = "$REMOTE_URL"
test "$(git remote get-url --push origin)" = "$REMOTE_URL"

git config user.name "Hermes"
git config user.email "hermes@wittner.tech"

has_remote_main=false
if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
  has_remote_main=true
  git fetch --prune origin "$BRANCH"
  git reset --hard "origin/$BRANCH"
  git clean -ffd
fi

# Replace only the declared Hermes profile paths in the sidecar-private checkout. The live .git
# directory, index and .gitignore are never consulted to decide what may be committed.
rm -rf workspace skills memories
rm -f config.yaml .hermes.md SOUL.md
for path in config.yaml .hermes.md SOUL.md workspace skills; do
  if [ -e "$SOURCE_DIR/$path" ]; then
    cp -a "$SOURCE_DIR/$path" .
  fi
done
if [ -f "$SOURCE_DIR/memories/USER.md" ]; then
  mkdir -p memories
  cp -a "$SOURCE_DIR/memories/USER.md" memories/USER.md
fi

git add --all -- config.yaml .hermes.md SOUL.md memories workspace skills
git diff --cached --check
if git diff --cached --quiet; then
  exit 0
fi
git commit -m "chore(hermes): synchronisation automatique"

if [ "$has_remote_main" = false ]; then
  git push -u origin "HEAD:$BRANCH"
elif git rebase "origin/$BRANCH"; then
  git push origin "HEAD:$BRANCH"
elif [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
  git rebase --abort
  git push --force origin "HEAD:$BRANCH"
else
  exit 1
fi
