# Changelog

All notable changes to this repository. Versions are immutable git tags `vX.Y.Z`; consumers pin the commit sha and keep the tag in a comment (see README).

## v1.0.0

First release.

### Composite actions

- `node-setup`: Node and package-manager setup from `.nvmrc` and `packageManager`, frozen install, Dockerfile runtime consistency check.
- `osv-scan`: OSV-Scanner over the lockfiles, `osv-scanner.toml` ignore entries must carry `ignoreUntil` and `reason`.
- `deploy-guard`: first job of a deploy workflow; allows only push or dispatch on a listed branch and computes the immutable image tag.
- `harbor-build`: registry login and `docker buildx build --push` of one or more images, with registry cache, BuildKit secret, OCI revision label and a hang watchdog.
- `k8s-setup`: checksum-verified kubectl install. `kubectl-version` and `kubectl-sha256` default to `RECORD-FIRST`, which fails on purpose: every caller records its own pin.
- `k8s-pin`: rewrites image tags in the CI checkout with positive and negative assertions.
- `k8s-apply`: refuses Secrets, server-side dry run first, records the workloads it touched.
- `k8s-job`: runs an immutable Job to `Complete` or `Failed` with diagnostics.
- `k8s-rollout`: waits for the recorded workloads in parallel under one deadline, with diagnostics.
- `release-gate`: tag-driven release safety (semver tag, version files, ancestry, green CI on the tagged commit).

### Scripts, tests, docs

- `scripts/buildkit-hang-watchdog.sh`: wraps a build, captures BuildKit diagnostics and kills it when it hangs.
- `test/run.sh` with fake `kubectl`, `docker` and `gh` on PATH; no cluster, daemon or network needed. The `Test` workflow runs `bash -n` on every script and then the suite on every pull request and push to `main`.
- `templates/` for `ci.yml`, `ci-lib.yml`, `deploy.yml`, `deploy-dev.yml`, the local `gate` action, `release-lib.yml` and `dependabot.yml`.
- `docs/STANDARD.md`: the conventions, the canonical deploy graph and the unit catalog.
