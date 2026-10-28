# CI/CD standard

How repositories that use these composite actions are laid out, what each action does, and how to adopt, bump and roll back. Everything here is generic: examples use `example-app` and `registry.example.com`.

The idea in one paragraph: each repository keeps its own thin workflows (`ci.yml`, `deploy.yml`, `deploy-dev.yml`, `release.yml`). The job graph, `needs`, timeouts, concurrency, `runs-on` and `environment` stay in the repository, so required-check names never move. The repetitive and security-sensitive steps (tagging, building, pinning, applying, waiting) live here as composite actions, referenced by commit sha. A new release of this repository changes nothing anywhere until a Dependabot pull request that bumps the sha is merged.

## 1. Consumer conventions

### Names

| File | `name:` | Job ids |
|---|---|---|
| `ci.yml` | `CI` | `quality`, `audit`, `build-check` (optional), `ci` |
| `deploy.yml` | `Deploy Production` | `guard`, `quality`, `audit`, `build`, `deploy` |
| `deploy-dev.yml` | `Deploy Dev` | same as `deploy.yml` |
| `release.yml` | `Release` | `release` (libraries with a build step: `build`, then `release`) |

The aggregator job `ci` is the only required status check. It runs with `if: always()`, lists every other job in `needs`, and fails when any result is `failure` or `cancelled`. Never require inner job names.

### Permissions, checkout, timeouts

- Top-level `permissions: contents: read`. Escalate per job only (`contents: write` in release jobs). Never `packages: write`.
- `persist-credentials: false` on every checkout, shallow.
- `timeout-minutes` on every job: guard 5, quality 20, audit 15, build-check 20, build 45, deploy 20, aggregator 2, library quality 15, release 10-20.
- Every `${{ }}` that reaches a script goes through `env:`, never inline in `run:`.
- Every action outside this repository is pinned to a 40-hex commit sha with the tag in a comment (`# v1.2.3`).

### Runners

Everything that does not touch the registry or the cluster runs on a hosted `ubuntu-latest` runner, including the quality gate and the dependency scan, so pull-request code and dependency install scripts never run next to cluster credentials. Only `build` and `deploy`, which need registry or cluster credentials, use a dedicated runner label (`<runner-label>`). Never a bare `self-hosted`. A workflow that triggers on `pull_request` has no job on the runner label used by the deploy jobs.

### The canonical deploy graph

```
on: push {branches: [<prod-branch>], paths-ignore: ['*.md', 'docs/**']} + workflow_dispatch (no inputs)

guard   ubuntu-latest  5   deploy-guard(branches=<prod-branch>)             outputs ref, tag
quality ubuntu-latest  20  needs guard                                      checkout(ref: guard.ref) + local gate
audit   ubuntu-latest  15  needs guard                                      checkout + osv-scan
build   <runner-label> 45  needs [guard, quality, audit]                    environment: production
                           concurrency build-<app>-prod (cancel false)      checkout + harbor-build
deploy  <runner-label> 20  needs [guard, build]                            environment: production
                           concurrency deploy-<app>-prod (cancel false)     checkout + k8s-setup + k8s-pin
                                                                            + ordered k8s-apply / k8s-job / local steps
                                                                            + k8s-rollout + post-deploy script
```

A plain `needs` is the gate: no custom `if` is needed, because a failed or skipped dependency stops the dependent job. `guard` stops a run that is not a push or dispatch on an allowed branch before anything else starts. `deploy.yml` stays a top-level workflow (not a reusable one) so branch rules, environments and runner restrictions can name it.

Dev (`deploy-dev.yml`): push to `develop` only, `environment: dev`, `tag-prefix: dev-`, `floating-tag: dev-latest`, `cache-ref: <project>/buildcache-dev`, `cache-from: <project>/buildcache`, `k8s-pin from: dev-latest`, build concurrency with `cancel-in-progress: true`, deploy never cancels.

### Image tags and apply order

- The tag is the 7-character commit sha from `deploy-guard` (`dev-` prefix on dev). It is immutable and the only tag the pipeline refers to.
- `:latest` / `:dev-latest` are optional convenience tags that the pipeline never references. Manifests in git carry that floating tag (or a `${GIT_SHA}` placeholder); `k8s-pin` rewrites it in the CI checkout only and never commits.
- No `kubectl set image`. Apply order: infrastructure, wait for the database, migration Job, app Deployments, rollout waits, post-deploy hook.
- Post-deploy hook: `bash scripts/ci/post-deploy.sh`, owned by the repository, `set -euo pipefail`, LF line endings.

### Runtime pinning

`.nvmrc` in every Node repository (exact patch for services, a major is fine for libraries), `packageManager` in every pnpm repository, and the Dockerfile agrees with both; `node-setup` enforces it. `node-setup` does not use corepack: pnpm comes from `packageManager` through `pnpm/action-setup`.

### Dependabot

`github-actions` only, weekly, one group, `cooldown: default-days: 7`, explicit `directories` (`/` plus `/.github/actions/gate` if it exists), `target-branch: develop` where a dev environment exists. See `templates/dependabot.yml`.

## 2. Synthetic example

A service `example-app` with images `example/app` and `example/migrate`, namespace `example`, production branch `main`, runner label `pool-example`, registry `registry.example.com`.

```yaml
name: Deploy Production

on:
  push:
    branches: [main]
    paths-ignore: ['*.md', 'docs/**']
  workflow_dispatch:

permissions:
  contents: read

jobs:
  guard:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    outputs:
      ref: ${{ steps.guard.outputs.ref }}
      tag: ${{ steps.guard.outputs.tag }}
    steps:
      - id: guard
        uses: Facilitra/ci/actions/deploy-guard@<sha> # v1.0.0
        with:
          branches: main

  # quality (local gate) and audit (osv-scan): see templates/deploy.yml

  build:
    needs: [guard, quality, audit]
    runs-on: pool-example
    timeout-minutes: 45
    environment: production
    concurrency:
      group: build-example-app-prod
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
        with:
          ref: ${{ needs.guard.outputs.ref }}
          persist-credentials: false
      - uses: Facilitra/ci/actions/harbor-build@<sha> # v1.0.0
        with:
          registry: ${{ vars.REGISTRY_HOST }}      # registry.example.com
          username: ${{ secrets.REGISTRY_USERNAME }}
          password: ${{ secrets.REGISTRY_PASSWORD }}
          tag: ${{ needs.guard.outputs.tag }}
          revision: ${{ needs.guard.outputs.ref }}
          images: |
            example/app
            example/migrate

  deploy:
    needs: [guard, build]
    runs-on: pool-example
    timeout-minutes: 20
    environment: production
    concurrency:
      group: deploy-example-app-prod
      cancel-in-progress: false
    steps:
      - uses: actions/checkout@<sha> # v7.0.1
        with:
          ref: ${{ needs.guard.outputs.ref }}
          persist-credentials: false
      - uses: Facilitra/ci/actions/k8s-setup@<sha> # v1.0.0
        with: {kubectl-version: <version>, kubectl-sha256: <sha256>}
      - uses: Facilitra/ci/actions/k8s-pin@<sha> # v1.0.0
        with:
          files: |
            k8s/app
            k8s/jobs
          images: |
            example/app
            example/migrate
          from: latest
          to: ${{ needs.guard.outputs.tag }}
      - uses: Facilitra/ci/actions/k8s-apply@<sha> # v1.0.0
        with:
          paths: k8s/app
          exclude: k8s/app/deployment.yaml
      - run: kubectl rollout status deployment/example-db -n example --timeout=180s
      - uses: Facilitra/ci/actions/k8s-job@<sha> # v1.0.0
        with: {namespace: example, manifest: k8s/jobs/migrate.yaml, name: example-migrate}
      - uses: Facilitra/ci/actions/k8s-apply@<sha> # v1.0.0
        with:
          paths: k8s/app/deployment.yaml
      - uses: Facilitra/ci/actions/k8s-rollout@<sha> # v1.0.0
        with:
          namespace: example
      - run: bash scripts/ci/post-deploy.sh
```

The complete files are in `templates/`.

## 3. Unit catalog

Every composite input is a string. Multi-line inputs take one item per line. In your own workflows pin each action as `Facilitra/ci/actions/<name>@<40-hex sha> # vX.Y.Z`.

### node-setup

Node and package-manager setup from the repository's own pins.

| Input | Default | Meaning |
|---|---|---|
| `package-manager` | `auto` | `auto` (pnpm-lock.yaml, then package-lock.json, then none), `pnpm`, `npm` or `none` |
| `node-version-file` | `.nvmrc` | Node version file |
| `working-directory` | `.` | where package.json lives |
| `install` | `true` | frozen install (`pnpm install --frozen-lockfile` or `npm ci`) |
| `check-versions` | `true` | run the runtime consistency check |
| `dockerfiles` | `Dockerfile .docker/Dockerfile` | Dockerfiles to check |

pnpm needs `packageManager` in package.json and `pnpm/action-setup` runs without a version input. The check requires `.nvmrc`; the Dockerfile Node tag (from `FROM ...node:<v>`, `ARG NODE_VERSION=` or any `ARG X=...node:<v>`) must equal `.nvmrc` exactly or its major; a floating tag next to an exact `.nvmrc` is a warning; a literal `pnpm@x` in a Dockerfile must equal `packageManager`.

### osv-scan

Dependency vulnerability scan with OSV-Scanner (v2.7.0 or newer). The scanner is a Docker container action, so run it on a hosted Linux runner.

| Input | Default | Meaning |
|---|---|---|
| `lockfiles` | empty | empty = autodetect at the root (pnpm-lock.yaml, package-lock.json, composer.lock, Cargo.lock, pubspec.lock); lockfiles in subdirectories must be listed, one per line |
| `working-directory` | `.` | where to scan |
| `fail` | `true` | `false` = report only |

Every `[[IgnoredVulns]]` entry in `osv-scanner.toml` needs `ignoreUntil` and `reason`. No lockfile is a notice, not a failure. An outage of the scanner fails the job. `fail: 'false'` must be justified by a same-line `# expires: YYYY-MM-DD` comment in the calling workflow. `npm audit` / `pnpm audit` are never a gate.

### deploy-guard

First job of every deploy workflow, hosted runner. No API calls, no token.

| Input | Default | Meaning |
|---|---|---|
| `branches` | required | branches allowed to deploy, newline or space separated bash case globs (`release/*` also matches `release/1/2`) |
| `tag-prefix` | empty | prefix of the tag (`dev-` on dev); empty, or starting with a letter, digit or `_`, then letters, digits, `.`, `_` and `-` |

Outputs: `ref` (full commit sha), `sha7`, `tag` (`<prefix><sha7>`). The event must be `push` or `workflow_dispatch` and `GITHUB_REF` must be `refs/heads/<b>` with `b` matching a glob, otherwise the job fails.

### harbor-build

Registry login plus `docker buildx build --push` for one or more images.

| Input | Default | Meaning |
|---|---|---|
| `registry` | required | hostname[:port], lowercase, validated before any login |
| `username`, `password` | required | registry credentials |
| `tag` | required | `^(dev-)?[0-9a-f]{7}$`, the first 7 characters of `revision` |
| `revision` | required | full commit sha, written to the `org.opencontainers.image.revision` label |
| `images` | required | one per line: `<path> [target=<t>] [file=<f>] [cache=<ref>] [watchdog=<seconds>]`; the first line is the primary image |
| `build-args` | empty | `KEY=VALUE` lines; values may contain spaces and quotes |
| `build-secret-id`, `build-secret-value` | empty | BuildKit secret, passed as `--secret id=<id>,env=...`, never as a build-arg |
| `file` | `Dockerfile` | Dockerfile for lines without `file=` |
| `context` | `.` | build context |
| `floating-tag` | `latest` | `latest` (plain tag), `dev-latest` (`dev-` tag) or `none` / empty for no extra tag; the extra tag is optional |
| `cache-ref` | empty | read+write registry cache; empty = `<project>/buildcache`, where project is the first path segment of the primary image; `none` disables |
| `cache-from` | empty | extra read-only cache refs, one per line |
| `watchdog-seconds` | `1500` | hang deadline of the primary build; the others get at most 900; `0` disables |

Output: `primary-image` (`<registry>/<path>:<tag>`).

The primary image builds first, in the foreground. It alone receives `build-args` and the secret, and it alone writes the registry cache (`type=registry,ref=<registry>/<ref>,mode=max`). The other images then build in parallel, read the cache, and run under their own watchdog; the step fails if any build fails, after all of them finished. `cache=<ref>` gives an image its own cache (read and write); `cache=none` turns the cache off for it. Arguments are kept in a bash array; nothing is evaluated by a shell. Every image gets the revision label and the tag `<registry>/<path>:<tag>`, plus the floating tag when set. `scripts/buildkit-hang-watchdog.sh` kills a build that is still running at its deadline after capturing BuildKit diagnostics (processes, connections, goroutine dump, kernel log), so the job fails in minutes with evidence instead of idling until the job timeout.

### k8s-setup

| Input | Default | Meaning |
|---|---|---|
| `kubectl-version` | `RECORD-FIRST` | kubectl version to install |
| `kubectl-sha256` | `RECORD-FIRST` | sha256 of the linux/amd64 binary |

Fails with a clear message while either is still `RECORD-FIRST`, so a workflow cannot deploy with an unrecorded pin. Pick a kubectl within one minor version of the cluster, then record its version (`vX.Y.Z`) and the sha256 from `https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl.sha256`. The action downloads kubectl from dl.k8s.io (linux/amd64 only), verifies the checksum, checks that the binary runs on the runner, installs it on the PATH, removes a directory at `~/.kube/config` if one exists, prints the client version, and warns when the installed binary reports another version than requested or when the cluster is more than one minor version away.

### k8s-pin

| Input | Meaning |
|---|---|
| `files` | manifest files or directories, one per line (required) |
| `images` | registry repository paths without host, for example `example/app`, one per line (required) |
| `from` | the literal tag currently committed in the manifests: `latest`, `dev-latest` or `${GIT_SHA}` (required) |
| `to` | the tag to write, normally the `tag` output of deploy-guard (required) |

Rewrites `image:` lines whose reference ends in `/<path>:<from>` (host-agnostic and anchored on the colon, so `web` never matches `web-tools`; literal comparison). Directories are read one level deep (`.yaml` and `.yml`). Covers containers, init containers, Jobs and CronJobs. Positive assertion: every listed path has at least one `image:` line, rewritten now or already at `to` (so a re-run of the same commit passes). Negative assertion: no remaining `image:` line for a listed path carries another tag. Flow-style or oddly quoted `image:` lines that mention a listed path with a tag are refused rather than left floating. `from` and `to` must differ. Prints an audit trail. Edits only the CI checkout.

### k8s-apply

| Input | Default | Meaning |
|---|---|---|
| `paths` | required | files or directories, one per line; a directory applies its `.yaml` and `.yml` files, one level deep, in sorted order |
| `exclude` | empty | globs, one per line, matched against the path as listed or the file name; an exclude that matches nothing fails the step |
| `dry-run-first` | `true` | `kubectl apply --dry-run=server` on the target set before the real apply |

Refuses any document with `kind: Secret`. Appends `kind/name` of every deployment, statefulset or daemonset it created, configured or left unchanged to `$RUNNER_TEMP/k8s-workloads.txt` for `k8s-rollout`. One call is one validation group: split calls where later paths depend on earlier ones (app Deployments after the database wait).

### k8s-job

| Input | Default | Meaning |
|---|---|---|
| `namespace`, `manifest`, `name` | required | where, which file, which Job |
| `timeout` | `300` | seconds, a positive number of up to 6 digits |
| `delete-first` | `true` | delete the (immutable) Job before applying |

Applies the manifest into `namespace` (`kubectl apply -n`, so a manifest in another namespace fails instead of running unwatched) and fails if the apply output does not name a Job called `name`, then polls every 5 seconds for `Complete` or `Failed` (`kubectl wait` never sees `Failed`). On failure or timeout it prints logs and `describe` and exits 1.

### k8s-rollout

| Input | Default | Meaning |
|---|---|---|
| `namespace` | required | namespace of the workloads |
| `timeout` | `300s` | per-workload wait |
| `timeouts` | empty | lines `name=Ns` overriding the timeout (a bare number means seconds) |
| `extra` | empty | `kind/name` lines to wait on that apply did not touch (`kind` is `deployment`, `statefulset` or `daemonset`; a bare name means a Deployment) |
| `skip` | empty | names not to wait on, `name` or `kind/name` |
| `optional` | empty | names whose failure is only a warning, `name` or `kind/name` |
| `deadline` | `900` | overall seconds |
| `diagnose` | `true` | print diagnostics on failure |

The wait list is the workloads recorded by `k8s-apply`, plus `extra`, minus `skip`. All waits run in parallel under the overall deadline. It warns when a Deployment container has no `readinessProbe`. `optional` failures warn; any other failure prints diagnostics (pods, describe, logs including init containers and `--previous`, events) in the same step and then fails. An empty list is a failure unless `extra` is set.

### release-gate

| Input | Default | Meaning |
|---|---|---|
| `tag` | required | the tag being released, `vX.Y.Z` |
| `version-files` | `package.json:version` | lines `path[:jsonpath]`; each must equal the tag without the `v` |
| `ci-workflow` | `ci.yml` | workflow whose push run on the tagged commit must pass |
| `branch` | empty | branch the commit must be on; empty = default branch |
| `wait-seconds` | `600` | how long to wait for that run to appear |
| `token` | required | token with `contents: read` and `actions: read` |

The job needs the tagged commit checked out (the version files are read from the working directory and the checked-out commit must be the tagged one) and `node` on the PATH, which hosted runners have. Run it in a job that has only `contents: read` and `actions: read`; any job with `contents: write` is a separate job that runs no dependency code.

## 4. Repository types

| Type | Files | Notes |
|---|---|---|
| Web service on Kubernetes, dev and production | `ci.yml`, `deploy.yml`, `deploy-dev.yml`, local `gate`, `dependabot.yml` | dev deploys on push to `develop`; production on the production branch |
| Web service on Kubernetes, production only | `ci.yml`, `deploy.yml`, local `gate`, `dependabot.yml` | optional `build-check` job in `ci.yml` |
| Library with tag releases | `ci.yml` (pull request and push to the default branch), `release.yml`, `dependabot.yml` | `release-gate` first; the job that writes releases runs no dependency code |
| Anything else | `ci.yml` with its own jobs plus the aggregator, `dependabot.yml` | nothing here is required; `osv-scan` applies wherever a lockfile exists, and every `uses:` is still sha-pinned |

## 5. Adopting in a repository

1. Add `.nvmrc` and `packageManager` where missing and make the Dockerfile agree (run `node-setup` on a branch to see what it reports).
2. Copy the templates you need from `templates/` into `.github/workflows/` and `.github/actions/gate/`, replace the placeholders, and replace `FACILITRA_CI_SHA` with the 40-hex commit of the release you adopt (keep `# v1.0.0` next to it).
3. Record `kubectl-version` and its linux/amd64 sha256 once from dl.k8s.io and put both in `k8s-setup`.
4. Make sure the manifests in git carry the floating tag you pass as `from` (`latest`, `dev-latest` or `${GIT_SHA}`) on every image you list in `k8s-pin`.
5. Run the local preflight below before the first real deploy.
6. Merge the adoption pull request, then run the first deploy at a quiet moment (`workflow_dispatch` on the production branch).

### Local preflight

Check what the pipeline will do to the cluster before it does it, on a throwaway copy and with your own kubeconfig. Never run this against the working tree you commit from.

```bash
# 1. a scratch copy of the repository (manifests included)
cp -r my-repo /tmp/preflight && cd /tmp/preflight

# 2. pin the images exactly as the pipeline would, to a plausible 7-character tag
INPUT_FILES=$'k8s/app\nk8s/jobs' \
INPUT_IMAGES=$'example/app\nexample/migrate' \
INPUT_FROM=latest INPUT_TO=0123abc \
  bash /path/to/ci/scripts/pin.sh

# 3. compare with the live cluster; use your own kubeconfig and context
kubectl --context my-context diff -f k8s/app -f k8s/jobs

# 4. optional: the server-side validation the pipeline runs before applying
kubectl --context my-context apply --dry-run=server -f k8s/app
```

`pin.sh` fails when a listed image is not found or another tag remains, which is the point of the preflight. `kubectl diff` exits 1 when there are differences, which is normal; the expected differences are the image tags (and nothing else). Anything else is drift between git and the cluster that you should understand before the first deploy.

## 6. Bumping this repository

Consumers reference actions as `Facilitra/ci/actions/<name>@<40-hex sha> # vX.Y.Z`. A release of this repository runs nothing in any consumer. The only way a consumer changes is a Dependabot pull request:

1. Install `templates/dependabot.yml` (`github-actions` only, weekly, grouped, `cooldown` 7 days, `target-branch: develop` where a dev environment exists).
2. When a new tag exists, Dependabot proposes one grouped pull request that rewrites every `uses:` line (sha and version comment).
3. Read the CHANGELOG entry, check that all `Facilitra/ci` lines in the repository moved to the same sha and that the sha belongs to the tag in the comment, and merge it on the dev branch first.
4. A bad release is handled by reverting the bump pull request. Tags are never moved or reused; a fix is a new patch release.
