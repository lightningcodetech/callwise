# Contributing

1. Open an issue first for anything beyond a small fix, so the design can be agreed before code is written.
2. Fork, branch from `main`, and run `npm ci` (installs the pre-commit hook that formats staged files).
   Follow the [conventions](#conventions) for branch names, commit messages and PR titles.
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

## Maintainers

### One-off setup

1. **Dev Hub**: enable _Dev Hub_ and _Unlocked Packages and Second-Generation Managed Packages_ in Setup.
2. **Create the package** (once; it writes `package`, `versionNumber` and `packageAliases` into
   `sfdx-project.json`, commit that):
   ```bash
   sf package create --name "Callwise" --package-type Unlocked --path force-app --no-namespace --target-dev-hub devhub
   ```
3. **CI secret**: add `DEVHUB_SFDX_AUTH_URL` in _Settings → Secrets and variables → Actions_:
   ```bash
   sf org display --target-org devhub --verbose --json | jq -r '.result.sfdxAuthUrl'
   ```

### Release

Bump `versionNumber` in `sfdx-project.json`, move the `[Unreleased]` entries in `CHANGELOG.md` under the new
version, merge to `main`, then tag:

```bash
git tag v0.1.0 && git push --tags
```

Tags with a suffix (`v0.2.0-beta.1`) create a beta version and a GitHub pre-release; plain tags are promoted.
