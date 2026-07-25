# Forgejo runner setup

A Forgejo runner executes the CI jobs defined in `.forgejo/workflows/`: fetch, patch, configure, build, sign, publish. `build-kernel.yml` runs the whole build directly inside one pinned `debian:trixie@sha256:…` job container, installing the kernel toolchain (`apt-get build-dep linux` + extras) at job start — there is no separate per-target image build today. (A pre-built runner image that bakes those deps in is a planned optimization; see the build-deps step in `build-kernel.yml`.)

## Topology

```
┌────────────┐   webhooks   ┌──────────────────────────────┐
│  Forgejo   │ ───────────► │   Runner = build host        │
│ (origin)   │              │   - one debian:trixie ctr    │
│            │              │   - kernel compile + sign    │
│            │              │   - signing via Forgejo      │
│            │              │     secrets (no HSM)         │
└────────────┘              └──────────────────────────────┘
```

The kernel + module signing key lives in Forgejo's secret store (`KERNEL_SIGNING_KEY`, `KERNEL_SIGNING_CERT`) and is materialized into the runner's tmpfs only for the duration of the `sign-debs.sh` step. Compromise of the Forgejo host is compromise of the signing key; that trade-off is accepted in exchange for build automation that meets the CVE-response SLA.

The runner holds:

- The kernel + module signing key (read-scoped to `build-kernel.yml`).
- The Fastly purge token (read-scoped to `publish.yml`).
- The Forgejo publish token (read-scoped to `publish.yml`).

The runner does **not** hold:

- The Forgejo apt-repo signing key; that lives only on the Forgejo host.

## Host sizing

A kernel build is CPU and disk heavy:

- 16+ vCPU.
- 32+ GB RAM (a full kernel build with all modules can hit 20+ GB resident at peak).
- 200+ GB SSD (per-target sources + build trees + .deb outputs).
- Stable network to the Forgejo host.

## Install

```
# Debian 13 host
sudo apt update && sudo apt install -y docker.io

# Pull the official runner image (pin the digest)
sudo docker pull code.forgejo.org/forgejo/runner:6@sha256:<DIGEST>
```

<!-- TODO: pin a concrete `code.forgejo.org/forgejo/runner` digest once a runner image is selected -->

## Register with the Forgejo instance

On the Forgejo side, generate a registration token: **Site Administration → Actions → Runners → Create new runner**. Copy the token.

On the runner host:

```
sudo mkdir -p /var/lib/forgejo-runner
sudo docker run --rm -v /var/lib/forgejo-runner:/data \
  code.forgejo.org/forgejo/runner:6@sha256:<DIGEST> \
  forgejo-runner register \
    --no-interactive \
    --instance https://git.unredacted.org \
    --token <REGISTRATION_TOKEN> \
    --name "$(hostname -s)-runner" \
    --labels "linux-hardened,debian-13,linux-hardened-host:host"
```

Two execution backends are registered on the one runner:

- **`linux-hardened`** (and `debian-13`) — the default docker-backed label. Jobs run in a container (the runner's default image, or the one a job names via `container:`, e.g. `build-kernel.yml`'s pinned `debian:trixie`). The build, sign, publish, and validate jobs use this.
- **`linux-hardened-host:host`** — host execution. Jobs run directly on the host shell, not in a container. **Only `repro-check.yml` uses it**, because it must run `docker run` itself (to rebuild in the recorded image) with bind-mount paths that resolve on the host. Keeping docker/host access on this separate label keeps it off the signing path. The host must have `docker`, `sbsigntool` (`sbattach`), `jq`, and `diffoscope` installed; `repro-check.yml` checks for them up front.

## Run as a service

`/etc/systemd/system/forgejo-runner.service`:

```ini
[Unit]
Description=Forgejo runner
After=docker.service
Requires=docker.service

[Service]
Type=simple
Restart=on-failure
RestartSec=10
ExecStart=/usr/bin/docker run --rm \
  --name forgejo-runner \
  -v /var/lib/forgejo-runner:/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  code.forgejo.org/forgejo/runner:6@sha256:<DIGEST> \
  forgejo-runner daemon

[Install]
WantedBy=multi-user.target
```

```
sudo systemctl daemon-reload
sudo systemctl enable --now forgejo-runner
```

The docker-socket mount lets the runner spawn each job's container (e.g. `build-kernel.yml`'s pinned `debian:trixie`) on the host docker daemon. The build runs *inside* that one container; there is no separate per-target image. `repro-check.yml` is the exception: it must run `docker` *itself* (to rebuild in the recorded image), and mounting the socket into a job container would break `tools/repro-check.sh`'s `docker run -v "$repo_root:/repo:ro"` (the path would resolve on the host, not in the job container). So that job runs on the **`linux-hardened-host`** label (host execution, above) instead of in a container — `docker run` then works natively and the bind mount is correct. The nightly cron therefore runs on the host; the host needs `docker`, `sbsigntool`, `jq`, and `diffoscope` pre-installed.

## Optional: pre-built runner image

`build-kernel.yml` installs the kernel-build toolchain (`apt-get build-dep linux` + extras) at the start of every build — ~5 minutes against a 20–60 minute build. To skip that, bake the toolchain into a runner image (`containers/Dockerfile.runner-trixie-amd64`) and use it as the job container:

```
# Build + push (on the runner host, or anywhere with docker + registry creds)
docker build -f containers/Dockerfile.runner-trixie-amd64 \
    -t git.unredacted.org/unredacted/runner-trixie-amd64:1 .
docker push git.unredacted.org/unredacted/runner-trixie-amd64:1
docker inspect --format '{{index .RepoDigests 0}}' \
    git.unredacted.org/unredacted/runner-trixie-amd64:1   # note the @sha256 digest
```

Then, in a **follow-up commit**, point `build-kernel.yml`'s `container.image` at the pushed image **by digest** and delete the "install build deps" step. Do it in that order — flipping the workflow before the image is in the registry breaks every build. Pinning by digest (not the `:1` tag) keeps builds reproducible: the toolchain is frozen at image-build time. The Dockerfile mirrors the workflow's inline dep list — keep it, the workflow, and `tools/repro-check.sh`'s inline rebuild deps in sync when any of them changes.

## Hardening

- The runner host runs no other services.
- SSH login is key-only, restricted by source IP.
- Outbound to anything except (a) the Forgejo origin, (b) the build host SSH port, (c) Fastly's purge API, (d) Debian's apt mirror is blocked at the host firewall.
- Automatic Debian security updates enabled.
- Off-host log shipping with alerts on: docker image pulls outside the configured digests, unexpected outbound connections, registration changes.
- Once the runner can grant the build container `CAP_SYS_ADMIN`, set the repo variable `REQUIRE_NET_ISOLATION=1`: `build-kernel.yml` then **hard-fails** if it can't isolate the compile in a network namespace (`unshare -n`) while the signing key is materialized in tmpfs. Today, without that capability, it logs a warning and compiles without isolation.

## Repo variables

Set these in the Forgejo UI under **Settings → Actions → Variables** (repo *variables*, not secrets — they carry no credential). A workflow only sees a variable if its step lists it in `env:`, so adding a name here is half the job; the other half is the `env:` entry, which `validate.yml` should eventually assert.

| Variable | Default when unset | Effect when set to `1` |
| -------- | ------------------ | ---------------------- |
| `REQUIRE_NET_ISOLATION` | warn and compile without a network namespace | **Hard-fail** the build if `unshare -n` is unavailable while the signing key is on disk. Set this once the runner can grant `CAP_SYS_ADMIN`. |
| `ALLOW_STALE_TAG` | hard-fail a tag that is behind `origin/main` | Downgrade to a warning and build anyway. For a deliberate rebuild of an old commit only — a stale tag builds an old seed pin and skips the drift guard. |
| `ALLOW_HARDENING_REGRESSION` | hard-fail on an inherited hardening symbol that regressed | Downgrade to a warning and continue. For a **reviewed** drop only (e.g. upstream removed the symbol); that release's `final.config` then becomes the new baseline. |

Leave all three unset for normal operation: each default is the safe one. `ALLOW_STALE_TAG` and `ALLOW_HARDENING_REGRESSION` are single-build overrides — unset them again once the build you needed them for has run, or the next genuine regression passes silently.

## Secret scoping

The per-workflow secrets (defined in the Forgejo UI) follow spec §6.1's principle of least privilege:

| Workflow | Secrets | Notes |
| -------- | ------- | ----- |
| `validate.yml` | none | |
| `build-kernel.yml` | `KERNEL_SIGNING_KEY`, `KERNEL_SIGNING_CERT`, `RELEASE_TOKEN` | Signing key for `sign-debs.sh`; release token (scope: `write:repository` on this repo) to attach .debs as release assets |
| `publish.yml` | `REGISTRY_USER`, `REGISTRY_TOKEN`, `FASTLY_SERVICE_ID`, `FASTLY_PURGE_TOKEN`, `RELEASE_TOKEN`, `MANIFEST_COMMIT_TOKEN` | Registry token (scope: `write:package` on this owner) to push to the Debian registry; release token to download .debs from the build's draft release; manifest-commit token (scope: `write:repository`) to push the updated manifest back |
| `cve-watch.yml` | `ISSUE_TOKEN` | scope: `write:issue` + `read:repository` (the issue-list dedup call needs repository read) |
| `seed-bump.yml` | `SEED_BUMP_TOKEN` | scope: `write:repository` (push a branch + open the seed-bump PR). It only ever opens a PR for human review — never merges, never cuts a kernel tag. |

Forgejo reserves secret names starting with `FORGEJO_`, `GITEA_`, and `GITHUB_`. The names above avoid those prefixes. Inside the runtime environment, the workflow YAML still sets env vars like `FORGEJO_TOKEN` for `tools/publish.py` to read — only the Forgejo-side secret names are constrained.

All of the API tokens above are personal access tokens issued from a dedicated **`unredacted-bot`** service account, not a maintainer's personal account. That keeps automated actions (issues, PRs, manifest commits, package uploads) attributable to the bot, and bounds a leaked CI token to the bot's access. The bot must be an org member / repo collaborator holding exactly the scopes listed: `write:package` on the `unredacted` owner, and `write:repository` / `write:issue` / `read:repository` on this repo. Operational consequences: rotating CI credentials means rotating the bot's PATs; if the bot account is disabled, all CI that needs a token stops; and if `main` is branch-protected, the bot must be allowed to push so `MANIFEST_COMMIT_TOKEN`'s manifest commit-back (and any future bot push to `main`) isn't blocked. (Signing keys are PEM material, not account tokens, so they're independent of the bot account.)

The signing key lives in Forgejo's secret store rather than an HSM. The runner reads the secret only for the duration of the signing step; the key is written to tmpfs and discarded when the step exits.

## Forgejo version requirements

The build → publish handoff uses Forgejo's release-asset API rather than the `actions/upload-artifact` ecosystem, because that ecosystem's compatibility varies across Forgejo versions and runner images. Any Forgejo version that supports releases (essentially all modern ones, 1.18+) will work; the instance currently runs **15.0.2**. Note Forgejo Actions does not implement the GitHub `workflow_run` trigger, which is why `repro-check.yml` is `workflow_dispatch` + cron rather than auto-chained off `publish`. Verify the version with:

```
curl -fsS https://git.unredacted.org/api/v1/version
```

If you upgrade Forgejo, re-run the build pipeline end-to-end against a test tag before relying on the next CVE response.
