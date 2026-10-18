#!/bin/sh
# Tests for git-wt and the Claude Code worktree hooks. Everything runs in a fresh
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
orig_path=$PATH
export PATH="$here:$PATH"
unset GIT_WT_REMAP GIT_WT_BASE_REF
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

# mkrepo <dir> <node|plain>: a clone with an origin, one unpushed commit, and
# gitignored files, some of which .worktreeinclude selects.
mkrepo() {
	git init -q --bare --template= -b main "$1.origin.git" || exit 1
	git init -q --template= -b main "$1" || exit 1
	(
		cd "$1" &&
			git remote add origin "$1.origin.git" &&
			if [ "$2" = node ]; then printf '{"name":"app"}\n' >package.json; fi &&
			printf '.local-config\nconfig/local.json\nnode_modules/\n' >.gitignore &&
			printf '.local-config\nconfig/local.json\n' >.worktreeinclude &&
			echo base >README &&
			git add -A && git commit -qm base &&
			git push -q origin main && git remote set-head origin main &&
			echo more >>README && git commit -qam unpushed &&
			echo setting=1 >.local-config &&
			mkdir -p config node_modules/dep &&
			echo '{}' >config/local.json &&
			echo 'module.exports = 1' >node_modules/dep/index.js
	) >>"$log" 2>&1 || { echo "mkrepo $1 failed" >&2; cat "$log" >&2; exit 1; }
}

create() {
	(cd "$2" && jq -nc --arg name "$1" --arg cwd "$2" \
		'{session_id: "s", transcript_path: "/dev/null", cwd: $cwd, name: $name}' |
		"$here/claude-worktree-create.sh") 2>>"$log"
}
remove() {
	jq -nc --arg p "$1" '{worktree_path: $p}' | "$here/claude-worktree-remove.sh" 2>>"$log"
}

repo="$tmp/my app" # the space is deliberate
mkrepo "$repo" node
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

echo '# WorktreeCreate hook'
out=$(create feat/x "$repo")
check "prints the remapped path" eq "$out" "$bucket/feat+x"
check "branch is worktree-<slug>" eq "$(git -C "$out" branch --show-current)" "worktree-feat+x"
check "fresh base is origin's default branch" eq "$(git -C "$out" rev-parse HEAD)" "$(git rev-parse origin/main)"
check "branch has no upstream" not git -C "$out" rev-parse --abbrev-ref '@{upstream}'
check ".worktreeinclude files are copied" test -f "$out/.local-config" -a -f "$out/config/local.json"
check "other ignored files are not copied" test ! -e "$out/node_modules"
check "nothing is created inside the repo" test ! -e "$repo/.claude"

check "re-requesting a name reuses the worktree" eq "$(create feat/x "$repo")" "$out"

head_out=$(GIT_WT_BASE_REF=head && export GIT_WT_BASE_REF && create headbase "$repo")
check "GIT_WT_BASE_REF=head branches from local HEAD" eq "$(git -C "$head_out" rev-parse HEAD)" "$(git rev-parse HEAD)"

check "uses the git-wt next to the hook when it is not on PATH" eq \
	"$(PATH=$orig_path && export PATH && create sibling "$repo")" "$bucket/sibling"

check "run from a linked worktree lands in the same bucket" eq "$(create from-linked "$out")" "$bucket/from-linked"

if bad=$(create ../escape "$repo"); then status=0; else status=1; fi
check "a name with .. fails" eq "$status" 1
check "a failed create prints no path" eq "$bad" ""

plain="$tmp/plain"
mkrepo "$plain" plain
pout=$(create p1 "$plain")
check "repos without package.json are remapped too" eq "$pout" "$GIT_WT_HOME/plain-$(hash_of "$plain")/p1"

echo '# WorktreeRemove hook'
echo dirty >>"$out/README"
check "a dirty worktree is refused" not remove "$out"
check "a dirty worktree is kept" test -d "$out"
git -C "$out" checkout -q -- README
check "a clean worktree is removed" remove "$out"
check "its directory is gone" test ! -e "$out"
check "its branch is kept" git show-ref --verify --quiet "refs/heads/worktree-feat+x"
check "the repo's only worktree is removed" remove "$pout"
check "the emptied per-repo folder is pruned" test ! -e "$(dirname "$pout")"
check "a missing path succeeds" remove "$tmp/nope"

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

# The plugin is self-contained: its WorktreeCreate hook uses the git-wt beside it.
createcmd=$(jq -r '.hooks.WorktreeCreate[0].hooks[0].command' "$here/hooks/hooks.json")
removecmd=$(jq -r '.hooks.WorktreeRemove[0].hooks[0].command' "$here/hooks/hooks.json")
pcreated=$(jq -nc --arg cwd "$repo" '{session_id: "s", transcript_path: "/dev/null", cwd: $cwd, name: "via-plugin"}' |
	PATH=$orig_path CLAUDE_PLUGIN_ROOT="$tmp/plugin root" sh -c "$createcmd" 2>>"$log")
check "hooks.json WorktreeCreate works without git-wt on PATH" eq "$pcreated" "$bucket/via-plugin"
jq -nc --arg p "$pcreated" '{worktree_path: $p}' |
	CLAUDE_PLUGIN_ROOT="$tmp/plugin root" sh -c "$removecmd" 2>>"$log"
check "hooks.json WorktreeRemove removes it" test ! -e "$pcreated"

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
