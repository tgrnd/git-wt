# git-wt

`git worktree add` that never nests a worktree inside a checkout.

A worktree created inside a repository (`<repo>/wt/x`, `<repo>/.claude/worktrees/x`) sits
under the outer checkout's `package.json`, `node_modules`, and tool configs. Anything that
walks up the tree (Node module resolution, workspace detection, ESLint/TypeScript config
lookup) sees the outer repo, and tools run in the outer repo scan the worktree as source.
`git wt add` moves such paths out of the checkout; paths already outside every checkout
pass through unchanged.

| Repo                                   | `git wt add wt/a` creates                 |
| -------------------------------------- | ----------------------------------------- |
| `~/Code/app`                           | `~/Code/.worktrees/app/wt/a`              |
| `~/Code/app/vendor/lib` (nested clone) | `~/Code/.worktrees/app+vendor+lib/wt/a`   |
| `~/Code/app/libs/sub` (submodule)      | `~/Code/.worktrees/app+libs+sub/wt/a`     |
| any, with `GIT_WT_HOME=~/wt`           | `~/wt/app-<hash>/wt/a`                    |

By default worktrees go in `.worktrees` beside the repo. A repo inside another checkout
uses the folder beside the outermost one, so nothing lands inside a checkout. Git
subtrees need nothing special: a subtree is part of the outer repo's history, not a repo
of its own. If that folder isn't writable (say the repo is your home folder), `git wt add`
fails and asks you to set `GIT_WT_HOME`.

## Install

```sh
brew install tgrnd/tap/git-wt
```

Or copy `git-wt` anywhere on your `PATH`; git runs `git-<name>` executables as `git <name>`.

## Usage

```sh
git wt add [--parent] [<git worktree add options>] <path> [<commit-ish>]
git wt path [--parent] <path>     # print where <path> would be created
git wt remove [--force] <path>    # git worktree remove, plus the parent copy if any
```

### Submodules that need their parent

A submodule (or nested clone) that only builds inside its parent, because it reads the
parent's config, workspace or sibling packages, can't work from a lone worktree.
`--parent` gives it a parent around it:

```sh
cd ~/Code/app/libs/sub
git wt add --parent -b feat wt/a
# parent copy: ~/Code/.worktrees/app+libs+sub/wt/a          (app, detached at its HEAD)
# work in:     ~/Code/.worktrees/app+libs+sub/wt/a/libs/sub (sub, on feat)
```

The parent copy is an ordinary worktree of the parent; it sees the child as its
submodule, so `git status` there shows ` M libs/sub` once the child has new commits.
If adding the child fails, the parent copy is removed again.

`git wt remove <child>` removes the child and then its parent copy. It refuses if the
parent copy has changes of its own (besides the child), so nothing is lost; `--force`
removes both anyway. On any other worktree it is plain `git worktree remove`.

| Variable       | Default                    | Meaning                                         |
| -------------- | -------------------------- | ----------------------------------------------- |
| `GIT_WT_HOME`  | unset: `.worktrees` beside the repo | One base folder for every repo's worktrees, as `<repo>-<hash>/<path>` |
| `GIT_WT_REMAP` | `1`                        | `0` passes every path through as given          |

Up to v0.3.0 the default was `~/.claude/.worktrees`. To keep that layout, set
`GIT_WT_HOME=~/.claude/.worktrees`; worktrees already there keep working either way.
In a sandboxed Claude Code session, `git wt add` can only write where the sandbox allows,
so either allow the `.worktrees` folder or set `GIT_WT_HOME` in Claude Code's `env`.

## Claude Code plugin

This repo is also a Claude Code plugin, installed separately from the command:

```sh
claude plugin marketplace add tgrnd/tgulls-grounded-plugins
claude plugin install git-wt@tgulls-grounded-plugins
```

Inside a session: `/plugin marketplace add tgrnd/tgulls-grounded-plugins`, then
`/plugin install git-wt@tgulls-grounded-plugins`. To try it from a checkout instead:
`claude --plugin-dir <path to this repo>`. The hook needs `jq`.

A PreToolUse hook rewrites `git [options] worktree add …` in Bash tool calls to
`git [options] wt add …` with the same arguments.

Worktrees Claude Code creates itself (`claude --worktree`, EnterWorktree, subagent
`isolation: worktree`) are left to Claude Code and stay under `<repo>/.claude/worktrees/`.
Moving them takes a WorktreeCreate hook, which replaces all of Claude Code's creation
(subagents included) and turns off its cleanup of them, so the plugin doesn't ship one.

- `git-wt` must be on `PATH` for this one (e.g. via Homebrew), because the rewritten
  command runs in Claude's shell. Without it the command is left as is and Claude Code
  shows a message saying why.
- The rewritten command always asks for approval: Claude Code documents rewritten input
  only with `allow` (which would bypass your permission rules) or `ask`.
- The hook runs on every Bash command but changes only `git [options] worktree add`;
  other `worktree` subcommands, `git wt`, and look-alikes (`git worktrees`, `echo worktree
  add`) pass through untouched (`test.sh` covers each).
- Matching is textual: `git` must start the command or follow whitespace or `; & | ( {`,
  and only git options (`-C <dir>`, `-c <k=v>`, `--git-dir <dir>`, `-p`, `--long[=value]`…),
  whitespace and `\` line continuations may sit between `git`, `worktree` and `add`. So
  quoted text such as `echo "x; git worktree add a"` is rewritten too.
- `GIT_WT_REMAP=0` in Claude Code's environment turns the rewrite off.

## Tests

```sh
sh test.sh
```
