#!/bin/sh
# Tests for git-wt and the Claude Code rewrite hook. Everything runs in a fresh
# directory under $TMPDIR with a private git config; nothing outside it is touched.
set -u

here=$(cd "$(dirname "$0")" && pwd -P) || exit 1

# The scratch dir is deleted on exit, so make sure it really is a new dir under $TMPDIR.
: "${TMPDIR:?TMPDIR must be set}"
tmp=$(mktemp -d "${TMPDIR%/}/git-wt-test.XXXXXX") || exit 1
[ -n "$tmp" ] && [ -d "$tmp" ] || { echo "mktemp gave no directory" >&2; exit 1; }
tmp=$(cd "$tmp" && pwd -P) || exit 1
tmproot=$(cd "$TMPDIR" && pwd -P) || exit 1
case $tmp in "$tmproot"/git-wt-test.?*) ;; *) echo "refusing unsafe scratch dir: $tmp" >&2; exit 1 ;; esac
trap 'rm -rf "$tmp"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_WT_HOME="$tmp/wt-home"
export HOME="$tmp/home" # so no fallback can reach the real home
export PATH="$here:$PATH"
unset GIT_WT_REMAP
log=$tmp/log

pass=0 fail=0
check() {
	desc=$1
	shift
	if "$@"; then
		pass=$((pass + 1))
		printf 'ok   %s\n' "$desc"
	else
		fail=$((fail + 1))
		printf 'FAIL %s\n' "$desc"
	fi
}
eq() { [ "$1" = "$2" ] || { printf '     expected: %s\n     actual:   %s\n' "$2" "$1"; return 1; }; }
not() { ! "$@" 2>>"$log"; }
hash_of() { printf '%s' "$1" | shasum | cut -c1-8; }
registered() { git worktree list --porcelain | grep -qxF "worktree $1"; }

# mkrepo <dir>: a repo with one commit.
mkrepo() {
	git init -q --template= -b main "$1" || exit 1
	(
		cd "$1" &&
			echo base >README &&
			git add -A && git commit -qm base
	) >>"$log" 2>&1 || { echo "mkrepo $1 failed" >&2; cat "$log" >&2; exit 1; }
}

repo="$tmp/my app" # the space is deliberate
mkrepo "$repo"
bucket="$GIT_WT_HOME/my app-$(hash_of "$repo")"
cd "$repo" || exit 1

echo '# git wt path'
check "nested path is remapped" eq "$(git wt path wt/a)" "$bucket/wt/a"
check ".claude/worktrees/ prefix is dropped" eq "$(git wt path .claude/worktrees/x)" "$bucket/x"
check "path outside the repo passes through" eq "$(git wt path "$tmp/elsewhere/a")" "$tmp/elsewhere/a"
check "GIT_WT_REMAP=0 passes through" eq "$(GIT_WT_REMAP=0 git wt path wt/a)" "$repo/wt/a"
check ".. segments are rejected" not git wt path wt/../../x

echo '# git wt add'
git wt add -b feat wt/feat >>"$log" 2>&1
check "worktree is created in the bucket" test -f "$bucket/wt/feat/README"
check "nothing is created inside the repo" test ! -e "$repo/wt"
check "worktree is registered with git" registered "$bucket/wt/feat"

git wt add --lock --reason 'keep me' -b locked wt/locked HEAD >>"$log" 2>&1
check "--reason value is not taken as the path" test -d "$bucket/wt/locked"
check "--lock --reason are passed through" eq \
	"$(git worktree list --porcelain | grep -A3 -xF "worktree $bucket/wt/locked" | grep '^locked')" "locked keep me"

git wt add -b dashdash -- wt/dd >>"$log" 2>&1
check "path after -- is remapped" test -d "$bucket/wt/dd"

(cd "$bucket/wt/feat" && git wt add -b inner wt/inner) >>"$log" 2>&1
check "path inside a linked worktree is remapped" test -d "$bucket/wt/inner"
check "nothing is nested in the linked worktree" test ! -e "$bucket/wt/feat/wt"

echo '# default home: .worktrees beside the outermost checkout'
home_path() { (unset GIT_WT_HOME && cd "$1" && git wt path "$2") 2>>"$log"; }
check "default home is ../.worktrees/<repo>" eq "$(home_path "$repo" wt/a)" "$tmp/.worktrees/my app/wt/a"
check "default home from a linked worktree is the same" eq \
	"$(home_path "$bucket/wt/feat" wt/b)" "$tmp/.worktrees/my app/wt/b"

# A repo inside another checkout must not put .worktrees inside that checkout.
mkrepo "$repo/vendor/inner"
check "a nested repo uses the outermost checkout's parent" eq \
	"$(home_path "$repo/vendor/inner" wt/a)" "$tmp/.worktrees/my app+vendor+inner/wt/a"

git -C "$repo" -c protocol.file.allow=always submodule add -q "$repo/vendor/inner" libs/sub >>"$log" 2>&1
check "a submodule uses the superproject's parent" eq \
	"$(home_path "$repo/libs/sub" wt/a)" "$tmp/.worktrees/my app+libs+sub/wt/a"
(unset GIT_WT_HOME && cd "$repo/libs/sub" && git wt add -b subwt wt/s) >>"$log" 2>&1
check "git wt add works in a submodule" test -f "$tmp/.worktrees/my app+libs+sub/wt/s/README"
check "nothing is created inside the superproject" test ! -e "$repo/libs/sub/wt"

echo '# --parent: a child worktree inside its own copy of the parent'
git -C "$repo" commit -qm 'add sub' >>"$log" 2>&1 # the parent copy is made from HEAD
wt_in() { (unset GIT_WT_HOME && cd "$1" && shift && git wt "$@") 2>>"$log"; }
sub_home="$tmp/.worktrees/my app+libs+sub"
check "path --parent names the child inside the parent copy" eq \
	"$(wt_in "$repo/libs/sub" path --parent wt/p)" "$sub_home/wt/p/libs/sub"

wt_in "$repo/libs/sub" add --parent -b pfeat wt/p >>"$log"
check "the parent copy is checked out" test -f "$sub_home/wt/p/README"
check "the parent copy is detached at the parent's HEAD" eq \
	"$(git -C "$sub_home/wt/p" rev-parse HEAD):$(git -C "$sub_home/wt/p" branch --show-current)" \
	"$(git -C "$repo" rev-parse HEAD):"
check "the child is checked out inside it" test -f "$sub_home/wt/p/libs/sub/README"
check "the child is on the new branch" eq "$(git -C "$sub_home/wt/p/libs/sub" branch --show-current)" pfeat
check "the parent copy starts clean" eq "$(git -C "$sub_home/wt/p" status --porcelain)" ''
git -C "$sub_home/wt/p/libs/sub" commit -q --allow-empty -m change >>"$log" 2>&1
check "the parent copy sees the child as its submodule" eq \
	"$(git -C "$sub_home/wt/p" status --porcelain)" ' M libs/sub'
check "--parent creates nothing inside the superproject" test ! -e "$repo/libs/sub/wt"

wt_in "$repo/vendor/inner" add --parent -b nfeat wt/n >>"$log"
check "--parent works for a nested clone" test -f "$tmp/.worktrees/my app+vendor+inner/wt/n/vendor/inner/README"

if wt_in "$repo" add --parent wt/x >>"$log"; then status=0; else status=1; fi
check "--parent fails in a repo with no parent" eq "$status" 1
check "... and creates nothing" test ! -e "$tmp/.worktrees/my app/wt/x"

if wt_in "$repo/libs/sub" add --parent -b pfeat wt/p2 >>"$log"; then status=0; else status=1; fi
check "a failed child add fails" eq "$status" 1
check "... and removes the parent copy it made" test ! -e "$sub_home/wt/p2"
check "... and unregisters it" not registered "$sub_home/wt/p2"

echo '# GIT_WT_PARENT: --parent by default'
# In POSIX sh, VAR=x before a function call outlives the call, so set it in a subshell.
parent_env() { (GIT_WT_PARENT=$1 && export GIT_WT_PARENT && shift && wt_in "$@"); }
check "GIT_WT_PARENT=1 makes path act as --parent" eq \
	"$(parent_env 1 "$repo/libs/sub" path wt/e)" "$sub_home/wt/e/libs/sub"
check "--no-parent overrides it" eq \
	"$(parent_env 1 "$repo/libs/sub" path --no-parent wt/e)" "$sub_home/wt/e"
check "GIT_WT_PARENT=0 leaves it off" eq \
	"$(parent_env 0 "$repo/libs/sub" path wt/e)" "$sub_home/wt/e"
parent_env 1 "$repo/libs/sub" add -b efeat wt/e >>"$log"
check "GIT_WT_PARENT=1 makes add check out the parent copy" test -d "$sub_home/wt/e/libs"
check "... with the child inside it" eq "$(git -C "$sub_home/wt/e/libs/sub" branch --show-current)" efeat
wt_in "$repo/libs/sub" remove "$sub_home/wt/e/libs/sub" >>"$log"
parent_env 1 "$repo/libs/sub" add --no-parent -b ofeat wt/o >>"$log"
check "add --no-parent overrides it" eq "$(git -C "$sub_home/wt/o" branch --show-current)" ofeat
wt_in "$repo/libs/sub" remove "$sub_home/wt/o" >>"$log"
if parent_env 1 "$repo" add wt/y >>"$log"; then status=0; else status=1; fi
check "GIT_WT_PARENT=1 fails in a repo with no parent" eq "$status" 1
check "... and creates nothing" test ! -e "$tmp/.worktrees/my app/wt/y"

echo '# git wt remove'
wt_in "$repo/libs/sub" remove "$sub_home/wt/p/libs/sub" >>"$log"
check "removing a child removes its parent copy" test ! -e "$sub_home/wt/p"
check "... and unregisters both" eq \
	"$(git -C "$repo" worktree list --porcelain | grep -cF "$sub_home/wt/p"):$(git -C "$repo/libs/sub" worktree list --porcelain | grep -cF "$sub_home/wt/p")" 0:0
check "... and keeps the child's branch" git -C "$repo/libs/sub" rev-parse -q --verify refs/heads/pfeat

wt_in "$repo/libs/sub" add --parent -b qfeat wt/q >>"$log"
echo edit >>"$sub_home/wt/q/README"
if (unset GIT_WT_HOME && cd "$repo/libs/sub" && git wt remove "$sub_home/wt/q/libs/sub") 2>"$tmp/rm.err"; then status=0; else status=1; fi
check "edits in the parent copy stop the removal" eq "$status" 1
check "... the error names the edited file" grep -q README "$tmp/rm.err"
check "... and nothing is removed" test -f "$sub_home/wt/q/libs/sub/README"
wt_in "$repo/libs/sub" remove --force "$sub_home/wt/q/libs/sub" >>"$log"
check "--force removes both anyway" test ! -e "$sub_home/wt/q"

wt_in "$repo/vendor/inner" remove "$tmp/.worktrees/my app+vendor+inner/wt/n/vendor/inner" >>"$log"
check "removing a nested-clone child removes its parent copy" test ! -e "$tmp/.worktrees/my app+vendor+inner/wt/n"

wt_in "$repo" remove "$bucket/wt/dd" >>"$log"
check "a plain worktree is removed as git worktree remove would" test ! -e "$bucket/wt/dd"

mkdir "$tmp/ro" && mkrepo "$tmp/ro/repo" && chmod 555 "$tmp/ro"
if (unset GIT_WT_HOME && cd "$tmp/ro/repo" && git wt add wt/a) 2>"$tmp/ro.err"; then status=0; else status=1; fi
chmod 755 "$tmp/ro"
check "an unwritable default home fails" eq "$status" 1
check "the failure points at GIT_WT_HOME" grep -q GIT_WT_HOME "$tmp/ro.err"

echo '# PreToolUse rewrite hook'
rewrite() {
	jq -nc --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c, description: "d", timeout: 5}}' |
		"$here/claude-rewrite-worktree-add.sh" 2>>"$log"
}
rewritten() {
	out=$(rewrite "$1")
	if [ -z "$out" ]; then echo '<unchanged>'; else printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command'; fi
}

check "git worktree add becomes git wt add" eq \
	"$(rewritten 'git worktree add -b x wt/x main')" 'git wt add -b x wt/x main'
check "a chained command is rewritten in place" eq \
	"$(rewritten 'cd app && git worktree add ../a')" 'cd app && git wt add ../a'
check "every occurrence is rewritten" eq \
	"$(rewritten 'git worktree add a;git worktree add b')" 'git wt add a;git wt add b'
check "git options before the subcommand are kept" eq \
	"$(rewritten 'git -C "my app" -c core.x=y --no-pager worktree add wt/a')" \
	'git -C "my app" -c core.x=y --no-pager wt add wt/a'
check "a trailing bare add is rewritten" eq "$(rewritten 'git worktree add')" 'git wt add'
# The hook sees every Bash command; only `git [opts] worktree add` may change.
for c in 'git worktree' 'git worktree list' 'git worktree list --porcelain' \
	'git worktree remove wt/add' 'git worktree remove add' 'git worktree prune' \
	'git worktree move wt/a wt/add' 'git worktree lock add' 'git worktree unlock wt/a' \
	'git worktree repair' 'git -C repo worktree remove x' 'git log --grep add worktree' \
	'git log worktree add' 'git commit -m "worktree add"' 'git worktree list | grep add' \
	'echo worktree add' 'ls worktree/add' 'git worktrees add a' 'git worktree-add a' \
	'git worktree "add" a' "git worktree list\\
 add"; do
	check "left alone: $c" eq "$(rewritten "$c")" '<unchanged>'
done
check "short git flags are skipped" eq "$(rewritten 'git -p worktree add a')" 'git -p wt add a'
check "--git-dir with a separate value is skipped" eq \
	"$(rewritten 'git --git-dir .git --work-tree=. worktree add a')" 'git --git-dir .git --work-tree=. wt add a'
check "a continuation after add is kept" eq "$(rewritten "git worktree add\\
 -b x a")" "git wt add\\
 -b x a"
check "continuations between git, options and worktree are allowed" eq "$(rewritten "git \\
  -C repo \\
  worktree \\
  add a")" "git \\
  -C repo wt add a"
check "only the add in a list-then-add chain changes" eq \
	"$(rewritten 'git worktree list && git worktree add a && git worktree prune')" \
	'git worktree list && git wt add a && git worktree prune'
check "a subshell or pipe start is a command boundary" eq \
	"$(rewritten '(git worktree add a) | cat')" '(git wt add a) | cat'
check "a quoted string starting with git is left alone" eq \
	"$(rewritten 'echo "git worktree add a"')" '<unchanged>'
check "known limit: quoted text after a separator is rewritten" eq \
	"$(rewritten 'echo "x; git worktree add a"')" 'echo "x; git wt add a"'
check "git wt add is left alone" eq "$(rewritten 'git wt add wt/a')" '<unchanged>'
check "a longer word is not matched" eq "$(rewritten 'git worktree addx; mygit worktree add a')" '<unchanged>'
check "GIT_WT_REMAP=0 disables the rewrite" eq \
	"$(GIT_WT_REMAP=0 && export GIT_WT_REMAP && rewritten 'git worktree add a')" '<unchanged>'
check "the rest of tool_input is kept" eq \
	"$(rewrite 'git worktree add a' | jq -c '.hookSpecificOutput.updatedInput | del(.command)')" '{"description":"d","timeout":5}'
check "the rewrite asks for approval" eq \
	"$(rewrite 'git worktree add a' | jq -r '.hookSpecificOutput.permissionDecision')" 'ask'
check "unrelated commands print nothing" eq "$(rewrite 'ls -la')" ''
check "input with no command prints nothing" eq \
	"$(jq -nc '{tool_name: "Read", tool_input: {}}' | "$here/claude-rewrite-worktree-add.sh")" ''

# Run hooks.json's command the way Claude Code does, from a plugin root with a space.
ln -s "$here" "$tmp/plugin root"
hookcmd=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$here/hooks/hooks.json")
check "hooks.json runs the hook from a plugin root with spaces" eq \
	"$(jq -nc '{tool_input: {command: "git worktree add a"}}' |
		CLAUDE_PLUGIN_ROOT="$tmp/plugin root" sh -c "$hookcmd" | jq -r '.hookSpecificOutput.updatedInput.command')" \
	'git wt add a'
check "hooks.json registers only the PreToolUse hook" eq \
	"$(jq -c '.hooks | keys' "$here/hooks/hooks.json")" '["PreToolUse"]'

# jq alone, since its usual directory (e.g. /opt/homebrew/bin) may also hold git-wt.
mkdir "$tmp/jq-only" && ln -s "$(command -v jq)" "$tmp/jq-only/jq"
nowt=$(PATH=$tmp/jq-only:/usr/bin:/bin && export PATH && rewrite 'git worktree add a')
check "without git-wt on PATH the command is not rewritten" eq \
	"$(printf '%s' "$nowt" | jq -r '.hookSpecificOutput.updatedInput // "none"')" 'none'
check "without git-wt on PATH the user is told why" eq \
	"$(printf '%s' "$nowt" | jq -r '.systemMessage | test("git-wt")')" 'true'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if [ "$fail" -gt 0 ]; then
	echo '--- log ---'
	cat "$log"
	exit 1
fi
