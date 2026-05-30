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
    --labels "linux-hardened,debian-13"
```

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

The docker-socket mount lets the runner spawn each job's container (e.g. `build-kernel.yml`'s pinned `debian:trixie`) on the host docker daemon. The build runs *inside* that one container; there is no separate per-target image. Note: a job that itself needs to run `docker` — e.g. `repro-check.yml`, which rebuilds in the recorded container image — would additionally need the socket mounted into its *own* container (and the docker CLI installed), which is not configured by default; run `tools/repro-check.sh` on a docker-capable host instead.

## Hardening

- The runner host runs no other services.
- SSH login is key-only, restricted by source IP.
- Outbound to anything except (a) the Forgejo origin, (b) the build host SSH port, (c) Fastly's purge API, (d) Debian's apt mirror is blocked at the host firewall.
- Automatic Debian security updates enabled.
- Off-host log shipping with alerts on: docker image pulls outside the configured digests, unexpected outbound connections, registration changes.
- Once the runner can grant the build container `CAP_SYS_ADMIN`, set the repo variable `REQUIRE_NET_ISOLATION=1`: `build-kernel.yml` then **hard-fails** if it can't isolate the compile in a network namespace (`unshare -n`) while the signing key is materialized in tmpfs. Today, without that capability, it logs a warning and compiles without isolation.

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
