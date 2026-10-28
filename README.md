# Facilitra/ci

Shared GitHub Actions building blocks for build, test and deploy pipelines: ten composite actions, the scripts behind them, workflow templates, and a test suite that needs no cluster, no Docker daemon and no network.

Repositories keep their own thin workflows (job graph, `needs`, timeouts, concurrency, runners, environments) and call these actions for the parts that are repetitive or security-sensitive. The conventions and the full unit catalog are in [docs/STANDARD.md](docs/STANDARD.md).

## Contents

| Path | What it is |
|---|---|
| `actions/<name>/action.yml` | `node-setup`, `osv-scan`, `deploy-guard`, `harbor-build`, `k8s-setup`, `k8s-pin`, `k8s-apply`, `k8s-job`, `k8s-rollout`, `release-gate` |
| `scripts/` | the bash behind each action (every action is a thin wrapper that calls one script) |
| `templates/` | workflow, local-gate and Dependabot templates with placeholders only |
| `docs/STANDARD.md` | conventions, canonical deploy graph, unit catalog, repository types, adoption and bump procedure |
| `test/` | `run.sh`, `lib.sh`, fake `kubectl` / `docker` / `gh`, one case file per unit |
| `CHANGELOG.md` | what changed in each release |

## Using an action

Reference an action by the full 40-character commit sha of a release and keep the tag in a comment:

```yaml
- uses: Facilitra/ci/actions/deploy-guard@<40-hex sha> # v1.0.0
  with:
    branches: main
```

Never use a tag or a branch there: the sha is what a reviewer can trust, and Dependabot rewrites the sha and the comment together. Use one sha per repository for all `Facilitra/ci` actions. Start from the files in `templates/`; `FACILITRA_CI_SHA` in them marks the place to put the sha.

To pick up a new release, install `templates/dependabot.yml`. It proposes one grouped pull request per release; merging it is the only way a consumer changes.

## How a release works

A release is an immutable tag, nothing more; it runs no workflow and touches no consumer.

1. Change the code on a branch and open a pull request. `main` accepts pull requests only, and the `Test` workflow (`bash -n` on every script, then `bash test/run.sh`) must pass.
2. Add an entry to `CHANGELOG.md` in the same pull request.
3. After merging, create an annotated tag `vX.Y.Z` on the merge commit and a GitHub release for it. Protect the tag pattern `v*.*.*` against updates and deletion in the repository rules.
4. Consumers receive it through their Dependabot pull request, review it, and merge it.

Never move or reuse a tag. A bad release is fixed by a new patch release; consumers revert their bump pull request in the meantime.

## Running the tests

```bash
bash test/run.sh                 # every case
bash test/run.sh harbor-build    # only the named case(s), with or without .sh
KEEP_TMP=1 bash test/run.sh k8s-pin   # keep each case's temp dir for inspection
```

Needs only bash 4.4 or newer (the default bash of macOS is too old), the usual POSIX tools (awk, sed, grep, coreutils) and node (for `release-gate`); one `release-gate` check also uses git when it is installed. It works on Linux and on Git Bash for Windows. `run.sh` runs each file in `test/cases/` as its own bash process with these variables:

| Variable | Meaning |
|---|---|
| `ROOT` | repository root |
| `TMP` | fresh temporary directory for the case, removed afterwards |
| `FAKEBIN` | `test/fakebin`, already first on `PATH` |
| `FAKE_DIR` | where a case puts canned output for the fakes (`$TMP/fake`) |
| `FAKE_LOG` | file the fakes append `<command> <args...>` to, one line per call |
| `KUBECONFIG` | `/nonexistent`, so a real `kubectl` can never reach a cluster |

`GITHUB_*`, `INPUT_*` and `RUNNER_*` variables of the calling environment are removed first, so a case behaves the same on a laptop and in a workflow run. A case sources `test/lib.sh` (`fail`, `pass`, `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_rc`), calls a script as `bash "$ROOT/scripts/<name>.sh"` with its inputs in `INPUT_<NAME>` variables, and checks the exit code, the output and what the fakes recorded. The suite exits non-zero if any case fails.
