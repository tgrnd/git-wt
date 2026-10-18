#!/bin/sh
# Claude Code WorktreeRemove hook: removes a worktree made by
# claude-worktree-create.sh. The branch is kept so no commits are lost; git refuses
# to remove a worktree with uncommitted changes, and that refusal is reported.
set -eu

die() { printf 'claude-worktree-remove: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"
path=$(jq -er '.worktree_path') || die "hook input has no .worktree_path"

if [ ! -e "$path" ]; then
	printf 'claude-worktree-remove: %s is already gone\n' "$path" >&2
	exit 0
fi

# Run git from the shared .git dir: a worktree cannot remove itself.
common=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
	die "$path is not a git worktree"
git --git-dir="$common" worktree remove "$path" >&2 ||
	die "git refused to remove $path; commit or stash its changes, or run: git worktree remove --force '$path'"

# Drop the per-repo folder once its last worktree is gone (rmdir only removes empty dirs).
parent=$(dirname "$path")
if [ -z "$(ls -A "$parent")" ]; then
	rmdir "$parent"
fi
