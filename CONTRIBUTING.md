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
