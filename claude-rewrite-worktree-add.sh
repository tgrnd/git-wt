#!/bin/sh
# Claude Code PreToolUse hook (Bash): rewrites `git [opts] worktree add` to
# `git [opts] wt add` with the same arguments, so worktrees Claude creates by hand
# never nest inside a checkout. Other worktree subcommands are left alone.
#
# The rewrite is returned with permissionDecision "ask": Claude Code documents
# updatedInput only with "allow" (which would skip your permission rules) or "ask",
# so you see and approve the rewritten command. Prints nothing when nothing changes.
#
# Matching is textual: an occurrence inside a quoted string (echo "git worktree add")
# is rewritten too, and a command split across lines with \ is not matched.
set -eu

die() { printf 'claude-rewrite-worktree-add: %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || die "jq is required"

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || die "hook input is not JSON"
[ -n "$cmd" ] || exit 0
[ "${GIT_WT_REMAP:-1}" != 0 ] || exit 0

sp='[[:space:]]'
arg="(\"[^\"]*\"|'[^']*'|[^[:space:]\"']+)"
# git's global options before the subcommand: -C <dir>, -c <k=v>, --long[=value]
opts="($sp+-[cC]$sp+$arg|$sp+--[^[:space:]]+)*"
# Groups: 1 = what precedes git, 2 = its options, 5 = what follows add.
new=$(printf '%s\n' "$cmd" |
	sed -E "s/(^|[;&|({[:space:]])git($opts)$sp+worktree$sp+add($sp|\$)/\\1git\\2 wt add\\5/g")
[ "$new" != "$cmd" ] || exit 0

# The rewritten command runs in Claude's Bash tool, so git-wt must be on PATH there.
if ! command -v git-wt >/dev/null 2>&1; then
	jq -nc '{systemMessage: "git-wt is not on PATH, so `git worktree add` was left unchanged and may nest the worktree inside the checkout. Install it (brew install tgrnd/tap/git-wt) or set GIT_WT_REMAP=0 to silence this."}'
	exit 0
fi

printf '%s' "$input" | jq -c --arg cmd "$new" '{
	hookSpecificOutput: {
		hookEventName: "PreToolUse",
		permissionDecision: "ask",
		permissionDecisionReason: "git-wt: `git worktree add` rewritten to `git wt add` so the worktree lands outside the checkout",
		updatedInput: (.tool_input + {command: $cmd})
	}
}'
