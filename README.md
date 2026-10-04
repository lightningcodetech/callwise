# Callwise

> One-line description of the problem this library solves.

## Install

Install links for every version are published in [Releases](../../releases).

```bash
sf package install --package <04t...> --wait 10 --target-org <your-org>
```

Or deploy the source directly: `sf project deploy start --source-dir force-app --target-org <your-org>`.

## Usage

```apex
// 10-line example
```

## Known limits

Document governor-limit costs and platform constraints here.

## License

BSD-3-Clause. See [LICENSE](LICENSE).

---

## Maintainer setup (one-off, delete this section once done)

1. **Dev Hub**: enable _Dev Hub_ and _Unlocked Packages and Second-Generation Managed Packages_ in Setup.
2. **Create the package** (once; it writes `package`, `versionNumber` and `packageAliases` into `sfdx-project.json`, commit that):
   ```bash
   sf package create --name "Callwise" --package-type Unlocked --path force-app --no-namespace --target-dev-hub devhub
   ```
3. **CI secret**: add `DEVHUB_SFDX_AUTH_URL` in _Settings → Secrets and variables → Actions_:
   ```bash
   sf org display --target-org devhub --verbose --json | jq -r '.result.sfdxAuthUrl'
   ```
4. **Release**: bump `versionNumber` in `sfdx-project.json`, update `CHANGELOG.md`, then
   ```bash
   git tag v0.1.0 && git push --tags
   ```
   Tags with a suffix (`v0.2.0-beta.1`) create a beta version and a GitHub pre-release; plain tags are promoted.
