# Contributing

1. Open an issue first for anything beyond a small fix, so the design can be agreed before code is written.
2. Fork, branch from `main`, and run `npm ci` (installs the pre-commit hook that formats staged files).
   Follow the [conventions](#conventions) for branch names, commit messages and PR titles, and the
   [Git workflow](#git-workflow).
3. Keep changes small and focused. Every Apex change ships with tests that assert behaviour, not just coverage.
4. Run `npm run prettier:verify && npm run lint && npm run test:unit` locally before opening the PR.
5. Update `CHANGELOG.md` under `[Unreleased]`.

Design rules for this repo:

- No dependencies on other packages unless strictly unavoidable.
- Every public method is part of the API: adding is cheap, removing is a breaking change.
- Document governor-limit cost for anything that does SOQL, DML, callouts or async work.

## Conventions

**Branches:** `<type>/<kebab-case-name>`, e.g. `feature/retry-engine`.

**Commit messages and PR titles:** `[<branch>] - <summary>`, e.g. `[feature/retry-engine] - add sync retries`.
The tag is always the branch the work belongs to. The summary is English, starts with a lower-case imperative verb,
has no trailing period and is at most 72 characters.

| Type       | Use for                                |
| ---------- | -------------------------------------- |
| `feature`  | New functionality                      |
| `bugfix`   | Bug fixes                              |
| `hotfix`   | Urgent fixes on a released version     |
| `refactor` | Code changes without behaviour changes |
| `test`     | Tests only                             |
| `docs`     | Documentation only                     |
| `ci`       | Workflows and pipeline                 |
| `chore`    | Tooling, dependencies, configuration   |
| `release`  | Version bumps and changelog            |

PRs are squash-merged, so the PR title becomes the commit on `main`. The `commit-msg` hook and CI enforce these
rules (`scripts/verify-commit-message.js`).

## Git workflow

Callwise follows [GitHub flow](https://docs.github.com/en/get-started/using-github/github-flow): one long-lived
branch, `main`, and short-lived topic branches. There is no `develop` branch: only the latest release is supported,
so the extra branches of git-flow would add work without adding safety.

**`main`** is always releasable. It is protected: changes only arrive through pull requests with green CI, and
force pushes and deletions are blocked. Every commit on `main` is one squash-merged PR.

**One branch per change.** Start every branch from an up-to-date `main`:

```bash
git switch main && git pull
git switch -c feature/circuit-breaker
```

Keep the branch focused on one change, open the PR as soon as it can be reviewed, and assign it to the maintainer.

**Keeping a branch up to date.** If `main` moves and the branch needs those changes (a conflict, or CI depends on
them), merge `main` into the branch and push:

```bash
git pull origin main
git push
```

Do not rebase or force-push branches that have an open PR: reviewers lose track of what changed, and the squash
merge already keeps `main` linear.

**Parallel work.** Two PRs can be open at the same time when they touch different files. When they touch the same
files, merge the first before starting the second. Do not stack PRs (a PR whose base is another topic branch): if the
top one is merged first, it lands in the topic branch instead of `main`.

**After the merge** GitHub deletes the remote branch. Clean up locally:

```bash
git switch main && git pull
git branch -D feature/circuit-breaker
git fetch --prune
```

`-D` is needed because squash merges create a new commit on `main`, so Git does not see the branch as merged.
Branch names can be reused once the old branch is deleted. Follow-up work on something already merged goes in a new
branch from `main`.

**Do not rename a branch with an open PR.** GitHub closes pull requests whose head branch is renamed. Fix the PR
title instead; the branch name only matters while the PR is open.

**Releases** are tags on `main`, not branches. A `release/vX.Y.Z` PR bumps the version and the changelog; after
merging it, tag `main` (see [Release](#release)).

**Hotfixes** for the latest release use a `hotfix/<name>` branch from `main` and ship as a patch release
(for example `v0.1.1`). Older releases are not patched.

## Maintainers

### One-off setup

1. **Dev Hub**: enable _Dev Hub_ and _Unlocked Packages and Second-Generation Managed Packages_ in Setup.
2. **Create the package** (once; it writes `package`, `versionNumber` and `packageAliases` into
   `sfdx-project.json`, commit that):
    ```bash
    sf package create --name "Callwise" --package-type Unlocked --path force-app --no-namespace --target-dev-hub devhub
    ```
3. **CI secret**: add `DEVHUB_SFDX_AUTH_URL` in _Settings → Secrets and variables → Actions_. CI uses it to
   validate every change in the Dev Hub org (check-only deploy plus this project's Apex tests), so no scratch
   orgs are created. Recent CLI versions hide secrets in `org display`, hence the variable:
    ```bash
    SF_TEMP_SHOW_SECRETS=true sf org display --target-org devhub --verbose --json \
      | jq -r '.result.sfdxAuthUrl' | gh secret set DEVHUB_SFDX_AUTH_URL
    ```

### Release

Open a `release/vX.Y.Z` PR that bumps `versionNumber` in `sfdx-project.json` and moves the `[Unreleased]` entries
in `CHANGELOG.md` under the new version. After merging it, tag `main`:

```bash
git switch main && git pull
git tag v0.1.0 && git push origin v0.1.0
```

Tags with a suffix (`v0.2.0-beta.1`) create a beta version and a GitHub pre-release; plain tags are promoted.
