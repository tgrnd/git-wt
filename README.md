# git-wt

`git worktree add` that never nests a worktree inside a checkout.

A worktree created inside a repository (`<repo>/wt/x`, `<repo>/.claude/worktrees/x`) sits
under the outer checkout's `package.json`, `node_modules`, and tool configs. Anything that
walks up the tree (Node module resolution, workspace detection, ESLint/TypeScript config
lookup) sees the outer repo, and tools run in the outer repo scan the worktree as source.
`git wt add` moves such paths to `$GIT_WT_HOME/<repo>-<hash>/<path>`; paths already
outside every checkout pass through unchanged.

## Install

```sh
brew install trev-gulls/tap/git-wt
```

Or copy `git-wt` anywhere on your `PATH`; git runs `git-<name>` executables as `git <name>`.

## Usage

```sh
git wt add [<git worktree add options>] <path> [<commit-ish>]
git wt path <path>    # print where <path> would be created
```

| Variable       | Default               | Meaning                               |
| -------------- | --------------------- | ------------------------------------- |
| `GIT_WT_HOME`  | `~/.claude/.worktrees` | Base folder for remapped worktrees    |
| `GIT_WT_REMAP` | `1`                   | `0` passes every path through as given |

## Claude Code hooks

`claude-worktree-create.sh` and `claude-worktree-remove.sh` replace Claude Code's built-in
worktree creation, which always nests worktrees under `<repo>/.claude/worktrees/`. The
create hook keeps Claude Code's naming (`worktree-<slug>` branches), rebuilds
`worktree.baseRef` (`GIT_WT_BASE_REF=fresh|head`) and copies `.worktreeinclude` files.
The remove hook keeps the branch and refuses worktrees with uncommitted changes.

Add to `~/.claude/settings.json` (Homebrew paths shown; `brew info git-wt` prints them):

```json
{
  "hooks": {
    "WorktreeCreate": [{ "hooks": [{ "type": "command", "command": "/opt/homebrew/opt/git-wt/libexec/claude-worktree-create.sh" }] }],
    "WorktreeRemove": [{ "hooks": [{ "type": "command", "command": "/opt/homebrew/opt/git-wt/libexec/claude-worktree-remove.sh" }] }]
  }
}
```

The hooks need `jq`. Claude Code's cleanup of stale worktrees only looks in
`.claude/worktrees`, so remove relocated ones with `git worktree remove` / `git worktree prune`.

## Claude Code plugin

This repo is also a Claude Code plugin (and its own marketplace). Its PreToolUse hook
rewrites `git [options] worktree add …` in Bash tool calls to `git [options] wt add …`
with the same arguments, so worktrees Claude creates by hand don't nest either.

```text
/plugin marketplace add trev-gulls/git-wt
/plugin install git-wt@git-wt
```

- `git-wt` must be on `PATH` (e.g. via Homebrew). Without it the command is left as is
  and Claude Code shows a message saying why.
- The rewritten command always asks for approval: Claude Code documents rewritten input
  only with `allow` (which would bypass your permission rules) or `ask`.
- Matching is textual: `git worktree add` inside a quoted string is rewritten too, and a
  command split across lines with `\` is not matched.
- `GIT_WT_REMAP=0` in Claude Code's environment turns the rewrite off.

## Tests

```sh
sh test.sh
```
