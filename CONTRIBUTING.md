# Contributing to Settle Up

## Branches

| Branch | Purpose |
| --- | --- |
| `main` | Released, stable code. Only `dev` (or a `hotfix/*`) is merged here. |
| `dev` | Integration branch. Every feature and fix is merged here first. |
| `feature/<name>` | New functionality, branched from `dev`, merged back into `dev`. |
| `fix/<name>` | Bug fixes, branched from `dev`, merged back into `dev`. |
| `hotfix/<name>` | Urgent fixes to a release, branched from `main`, merged into `main` and `dev`. |
| `chore/<name>` | Tooling, CI, dependencies, docs housekeeping. |
| `docs/<name>` | Documentation-only changes. |

Use short kebab-case names, for example `feature/lan-sync` or `fix/rounding-remainder`.

## Workflow

1. `git checkout dev && git pull`
2. `git checkout -b feature/<name>`
3. Commit in small steps with messages in the imperative mood ("Add split-by-shares editor").
4. Push the branch and open a pull request into `dev`.
5. Before merging: `flutter analyze` is clean and `flutter test` passes.

## Commit messages

Commits are authored by the repository owner (`sushil3125`). Messages have
a subject in the imperative mood, an optional body, and no attribution
lines: no `Co-Authored-By` for a tool or assistant, no session links and no
"Generated with" lines. The same applies to code and docs.

Enable the hook once per clone (it applies to every worktree):

```sh
git config core.hooksPath tool/git-hooks
```

`tool/git-hooks/commit-msg` then rejects a message with such lines. Before
pushing to `dev` or `main`, check the commits that would land:

```sh
tool/check_commit_messages.sh origin/dev..HEAD
```

A branch whose history already has such lines (for example
`qa/integration` from QA round 1) is not merged with a merge commit and is
never rewritten with a force push. Squash merge it instead, which keeps its
tree and lists the merged subjects without their bodies:

```sh
git checkout dev && git pull --ff-only
tool/squash_merge.sh origin/qa/integration "Merge QA fixes for 1.0.0"
tool/check_commit_messages.sh origin/dev..HEAD
git push origin dev
```

On GitHub, "Squash and merge" pre-fills the message with every commit body,
trailers included: replace it with a clean message before confirming.
