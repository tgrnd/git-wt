#!/bin/sh
# Claude Code WorktreeCreate hook: creates the worktree Claude asked for through
# `git wt add`, so it lands outside the repository instead of under
# <repo>/.claude/worktrees/. Prints the worktree path on stdout (the hook's answer);
# everything else goes to stderr.
#
# Because this hook replaces Claude Code's own creation, it also rebuilds the two
# built-in behaviours that would otherwise be lost:
#   - worktree.baseRef: GIT_WT_BASE_REF=fresh (default, branch from origin's default
#     branch) or head (branch from the current checkout's HEAD)
#   - .worktreeinclude: gitignored files matching its patterns are copied in
set -eu

die() { printf 'claude-worktree-create: %s\n' "$*" >&2; exit 1; }
log() { printf 'claude-worktree-create: %s\n' "$*" >&2; }

# Prefer the git-wt beside this script (the plugin ships both); hooks run with
# whatever PATH Claude Code was started with.
PATH=$(cd "$(dirname "$0")" && pwd -P):$PATH
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git-wt >/dev/null 2>&1 || die "git-wt is not beside this hook or on PATH"

input=$(cat)
name=$(printf '%s' "$input" | jq -er '.name') || die "hook input has no .name"
cwd=$(printf '%s' "$input" | jq -er '.cwd') || die "hook input has no .cwd"

case $name in '' | /* | *..*) die "refusing worktree name: $name" ;; esac
if printf '%s' "$name" | LC_ALL=C grep -q '[^A-Za-z0-9._/+-]'; then
	die "refusing worktree name with unsupported characters: $name"
fi

cd "$cwd" || die "cannot enter $cwd"
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
	die "not inside a git repository: $cwd"
root=$(cd "$(dirname "$common")" && pwd -P)

# Same naming as Claude Code: slug replaces / with +, branch is worktree-<slug>.
slug=$(printf '%s' "$name" | tr '/' '+')
branch=worktree-$slug
requested=$root/.claude/worktrees/$slug
dest=$(git wt path "$requested")

# Resuming a session re-requests the same name: hand back the existing worktree.
if [ -e "$dest" ]; then
	top=$(git -C "$dest" rev-parse --show-toplevel 2>/dev/null || true)
	if [ -n "$top" ] && [ "$(cd "$top" && pwd -P)" = "$(cd "$dest" && pwd -P)" ]; then
		log "reusing existing worktree $dest"
		printf '%s\n' "$dest"
		exit 0
	fi
	die "$dest exists but is not a worktree; remove it or choose another name"
fi

case ${GIT_WT_BASE_REF:-fresh} in
head) start=$(git rev-parse HEAD) ;;
fresh)
	start=$(git rev-parse HEAD)
	if default=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
		if git fetch --quiet origin "${default#origin/}" >&2; then
			start=$(git rev-parse "$default")
		else
			log "fetching $default failed; branching from the current HEAD"
		fi
	else
		log "origin has no default branch; branching from the current HEAD"
	fi
	;;
*) die "GIT_WT_BASE_REF must be fresh or head, not: $GIT_WT_BASE_REF" ;;
esac

if git show-ref --verify --quiet "refs/heads/$branch"; then
	git wt add "$requested" "$branch" >&2
else
	git wt add --no-track -b "$branch" "$requested" "$start" >&2
fi

include=$root/.worktreeinclude
if [ -f "$include" ]; then
	list=$(mktemp "${TMPDIR:-/tmp}/worktreeinclude.XXXXXX") || die "mktemp failed"
	trap 'rm -f "$list"' EXIT
	git -C "$root" ls-files -z --others --ignored --exclude-from="$include" >"$list"
	(cd "$root" && xargs -0 sh -c '
		for f do
			mkdir -p "$0/$(dirname "$f")" && cp -p "$f" "$0/$f" || exit 1
		done' "$dest" <"$list") || die "copying .worktreeinclude files into $dest failed"
fi

printf '%s\n' "$dest"
