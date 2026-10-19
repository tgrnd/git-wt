#!/bin/sh
# Claude Code PreToolUse hook (Bash): rewrites `git [opts] worktree add` to
# `git [opts] wt add` with the same arguments, so worktrees Claude creates by hand
# never nest inside a checkout. Other worktree subcommands are left alone.
#
# The rewrite is returned with permissionDecision "ask": Claude Code documents
# updatedInput only with "allow" (which would skip your permission rules) or "ask",
# so you see and approve the rewritten command. Prints nothing when nothing changes.
#
# Matching is textual: `git` must start the command or follow whitespace or one of
# ; & | ( {, and only git options, whitespace and \ line continuations may sit
# between git, worktree and add. Quoted text such as echo "x; git worktree add a"
# is rewritten too.
set -eu

die() { printf 'claude-rewrite-worktree-add: %s\n' "$*" >&2; exit 1; }

input=$(cat)
# Every Bash command comes through here; skip the ones that can't match before
# starting jq.
case $input in *git*worktree*add*) ;; *) exit 0 ;; esac
[ "${GIT_WT_REMAP:-1}" != 0 ] || exit 0

command -v jq >/dev/null 2>&1 || die "jq is required"

# Oniguruma regex (jq): (?:...) groups, named captures and lookahead keep this
# readable, and it matches across the newlines of \ continuations.
ws='(?:\s|\\\n)'
arg="(?:\"[^\"]*\"|'[^']*'|[^\\s\"']+)"
# git's global options: -C/-c/--git-dir/--work-tree/--namespace <value>, -<letter>,
# or --long[=value].
opt="(?:$ws+(?:-[cC]|--(?:git-dir|work-tree|namespace))$ws+$arg|$ws+-[A-Za-z]|$ws+--[^\\s]+)"
re="(?<pre>^|[;&|({\\s])git(?<opts>$opt*)$ws+worktree$ws+add(?=\\s|\\\\|\$)"

cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty') || die "hook input is not JSON"
[ -n "$cmd" ] || exit 0
new=$(printf '%s' "$input" | jq -r --arg re "$re" '.tool_input.command | gsub($re; "\(.pre)git\(.opts) wt add")') ||
	die "rewriting the command failed"
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
