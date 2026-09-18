#!/bin/sh
set -eu

REPO_DIR=/opt/data
# The remote is injected from the `hermes-git` ConfigMap so that this script and the git-sync
# sidecar can never disagree on which repository holds the profile. Fail loudly rather than
# bootstrapping against an implicit default.
REPO_URL=${HERMES_REPO_URL:?HERMES_REPO_URL is required}
BRANCH=main

# An existing checkout is the authoritative live worktree. Only an empty PVC (apart from the
# filesystem's lost+found) may be bootstrapped; never overlay an unknown partial state.
if [ -e "$REPO_DIR/.git" ]; then
  exit 0
fi
for entry in "$REPO_DIR"/* "$REPO_DIR"/.[!.]* "$REPO_DIR"/..?*; do
  [ -e "$entry" ] || continue
  [ "${entry##*/}" = lost+found ] && continue
  printf '%s\n' 'refusing to bootstrap a non-empty PVC without .git' >&2
  exit 1
done

export GIT_ASKPASS=/bootstrap/git-askpass.sh
export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=core.hooksPath
export GIT_CONFIG_VALUE_0=/dev/null

# A brand-new Forgejo repository has no main ref and cannot be cloned. Initialize its local
# counterpart; the sync sidecar creates and pushes the first commit once Hermes has written data.
if ! git ls-remote --exit-code --heads "$REPO_URL" "$BRANCH" >/dev/null 2>&1; then
  git init --initial-branch "$BRANCH" "$REPO_DIR"
  git -C "$REPO_DIR" remote add origin "$REPO_URL"
  chown -R 10000:10000 "$REPO_DIR"
  exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT INT TERM

git clone --branch "$BRANCH" --single-branch "$REPO_URL" "$workdir/repo"
source="$workdir/repo"

# Retain the trusted clone metadata and the immutable ignore policy, then copy only the profile
# paths that are declared reconstructible. Runtime state and credentials never enter the PVC here.
cp -a "$source/.git" "$REPO_DIR/.git"
[ ! -f "$source/.gitignore" ] || cp -a "$source/.gitignore" "$REPO_DIR/.gitignore"
for path in config.yaml .hermes.md SOUL.md workspace skills; do
  if [ -e "$source/$path" ]; then
    cp -a "$source/$path" "$REPO_DIR/"
  fi
done
if [ -f "$source/memories/USER.md" ]; then
  mkdir -p "$REPO_DIR/memories"
  cp -a "$source/memories/USER.md" "$REPO_DIR/memories/USER.md"
fi
chown -R 10000:10000 "$REPO_DIR"
