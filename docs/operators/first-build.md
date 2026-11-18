# First Phase 1 build: a walkthrough

The first end-to-end build on real infrastructure is where the implicit assumptions get tested. This document walks through every command, in order. Allocate half a day; expect things to fail.

## What you'll have when you're done

A test tag (e.g. `v0.0.0-hardened1`) pushed against a known-small kernel; CI built it, signed it, attached `.debs` to a draft release; you ran `publish.yml` manually; you installed the `.deb` on a clean Debian 13 VM, enrolled MOK, booted the hardened kernel, and confirmed module signature verification.

If any of the above doesn't work, fix what broke before pushing the first real tag.

## Prerequisites

Have these ready before you start:

- A Linux machine with Docker, registered as a Forgejo runner with label `linux-hardened`.
- A Forgejo instance at `git.unredacted.org` with the repo at `unredacted/linux-hardened-unredacted`.
- A Fastly account (on the OSS program) with a service pointing at `repo.unredacted.org`.
- Pangolin in front of the Forgejo origin (ordinary reverse proxy; no Debian-path rules — see [reverse-proxy.md](reverse-proxy.md)).
- A clean Debian 13 amd64 VM for the install test (UEFI firmware, Secure Boot enabled).

## 1. Pin the container digest

```
docker pull debian:trixie
docker inspect debian:trixie | jq -r '.[0].RepoDigests[0]'
```

The output looks like `debian@sha256:abc123...`. Substitute the digest portion for the placeholder in `containers/Dockerfile.debian-trixie-amd64`:

```
sed -i 's/sha256:REPLACE_WITH_CONCRETE_DIGEST/sha256:abc123.../' \
    containers/Dockerfile.debian-trixie-amd64
```

Commit and push the change. The `no-placeholder-digests` validator job will pass on push to main.

## 2. Retrieve the apt-repo signing key fingerprint

Forgejo's Debian registry manages its own GPG key per owner — there is nothing to generate by hand (unlike the kernel key in step 3). The key is minted lazily; fetching the public key both creates and returns it:

```
curl -fsS https://git.unredacted.org/api/packages/unredacted/debian/repository.key -o unredacted-apt.asc
gpg --show-keys unredacted-apt.asc
```

Record the displayed fingerprint and insert it into:
- `README.md` (the apt-repo key fingerprint line)
- `SECURITY.md` (out-of-band verification section)
- `docs/users/verifying-packages.md` (canonical fingerprint sources)

Commit. Publish the same fingerprint at https://unredacted.org and a Keyoxide profile, so users have at least two independent sources to verify against. Re-check the fingerprint after the first publish; the lazily-minted key persists (Forgejo's get-or-create), but confirming it matches the `InRelease` signer before announcing to users costs nothing.

## 3. Generate the kernel + module signing key

On a clean, network-isolated workstation, follow [signing-key-procedures.md](signing-key-procedures.md) verbatim:

```
openssl req -new -nodes -utf8 -sha256 -days 1825 \
    -batch -x509 -subj "/CN=unredacted linux-hardened signing/" \
    -newkey rsa:3072 \
    -keyout signing.key \
    -outform PEM -out signing.crt
```

Load both files into Forgejo as repository-scoped secrets:
- `KERNEL_SIGNING_KEY` ← contents of `signing.key`
- `KERNEL_SIGNING_CERT` ← contents of `signing.crt`

Restrict both to `build-kernel.yml` only.

Shred the workstation copy of `signing.key`. Keep an offline encrypted backup per the procedures doc.

## 4. Provision the other Forgejo secrets

In the same Forgejo repo settings, add:

| Secret | Value |
| ------ | ----- |
| `REGISTRY_USER` | The bot account that will own uploads (e.g. `unredacted-bot`) |
| `REGISTRY_TOKEN` | Personal access token with `write:package` on owner `unredacted` |
| `RELEASE_TOKEN` | Token with `write:repository` on `unredacted/linux-hardened-unredacted` |
| `MANIFEST_COMMIT_TOKEN` | Token with `write:repository` (push to main) on `unredacted/linux-hardened-unredacted` |
| `ISSUE_TOKEN` | Token with `write:issue` + `read:repository` on `unredacted/linux-hardened-unredacted` |
| `SEED_BUMP_TOKEN` | Token with `write:repository` on `unredacted/linux-hardened-unredacted` (push a branch + open the automated seed-bump and source-bump PRs; `seed-bump.yml`, `source-bump.yml`) |

Forgejo reserves secret names starting with `FORGEJO_`, `GITEA_`, and `GITHUB_`, so the secrets above use neutral prefixes. The workflow YAML maps each one to whatever env var name the script expects internally.

Scope each to the workflows that need it (see the table in [runner-setup.md](runner-setup.md)). Don't reuse one token across workflows.

## 5. Configure Fastly

Apply the VCL from [fastly-config.md](fastly-config.md) to the service serving `repo.unredacted.org`: the `/debian/` → `/api/packages/unredacted/debian/` path rewrite, the cache-policy TTLs, and the surrogate-key tagging that `publish.py` purges against. There is no `X-Origin-Auth` header — the apt repo is public and served both via Fastly and directly from the origin.

Add Fastly secrets to Forgejo:

| Secret | Value |
| ------ | ----- |
| `FASTLY_SERVICE_ID` | The service ID from Fastly's UI |
| `FASTLY_PURGE_TOKEN` | API token with `purge_select` permission on this service only |

## 6. Configure Pangolin

Pangolin needs only the ordinary Forgejo reverse-proxy setup for `git.unredacted.org`: forward to the Forgejo backend, terminate TLS, no Debian-path-specific rules. The apt repo is public, and uploads authenticate with the `REGISTRY_TOKEN`, so there is no read gate and no upload exception. See [reverse-proxy.md](reverse-proxy.md) for the verification curls.

## 7. Reconcile our seed + intent against upstream

The build composes `.config` from anthraxx's pinned `config.x86_64` seed plus the intent fragments `configs/intent.common.config` and `configs/intent.x86_64.config` (the amd64 flavor's list, in `configs/flavors/amd64.toml`). Per kernel bump, two failure modes are possible at configure time:

- **Fidelity miss:** an intent line didn't land in the final `.config` after merge+olddefconfig. The configure step aborts naming the symbol. Usually means the seed's dependency graph shifted (e.g. a parent symbol flipped off, masking our child pin) or the symbol was renamed upstream. Fix: pin the parent in the same fragment, or update the fragment + `POLICY.md` to the new name.
- **Anthraxx changed config.x86_64 in a way we want to adopt:** not detected by the build (the pin is static). Run `tools/reconcile-vs-anthraxx.sh` to see hardening-relevant deltas; `tools/bump-seed.sh <commit-or-tag>` to update the pin if you want to adopt them.

```
# Diff our pinned seed against anthraxx HEAD (read-only)
tools/reconcile-vs-anthraxx.sh

# If you want to adopt their changes, bump the pin (signature + sha256
# verified; prints the hardening-relevant delta for the commit message)
# Always name the line explicitly: without --pin-file the target is the
# upstream-seed.toml symlink (whichever line is currently stable), so a ref
# from an older series would rewrite the current line's pin to that config.
tools/bump-seed.sh --pin-file configs/seeds/7.1.toml 7.1.4.hardened1-1
```

The `intent-matches-policy` CI check (`.forgejo/workflows/validate.yml`) enforces bidirectional parity between the intent fragments (`configs/intent.*.config`) and `configs/POLICY.md` — update both together when changing one. Full design in [config-architecture.md](config-architecture.md).

## 8. Push a stub test tag

Pick a small, well-known kernel to use as a smoke test. v6.6.x LTS is reasonable; v6.12.8-hardened1 (or whatever's current) if you trust the audit.

```
git tag v6.6.0-hardened1 -m "smoke test"
git push origin v6.6.0-hardened1
```

`build-kernel.yml` triggers. Watch the workflow in the Forgejo UI.

**What will probably fail the first time:**

- Some package missing from `containers/Dockerfile.debian-trixie-amd64`. Add it, rebuild the image.
- The configure step's fidelity assertion aborts because an intent line didn't land — inspect the symbol named in the error, decide whether to pin a parent symbol in the same intent fragment, update the intent value to match what landed, or (rarely) bump the seed pin via `tools/bump-seed.sh` to inherit anthraxx's choice.
- Pangolin's allow rule for the runner IP isn't quite right; CI uploads 403. Re-check step 6.
- The signing step fails because the secret was loaded with stray whitespace. Re-add the secret without the trailing newline.
- `debian/patches/` was already empty in this kernel version, so the truncate is a no-op. Fine.
- `apt-get source linux=$version` fails because the trixie apt index has rotated to a newer version. Either point at snapshot.debian.org or accept that the pinned version changes per-build.

Each failure is a learning. Fix, push the fix, re-tag if necessary (`git tag -d v6.6.0-hardened1 && git push origin :refs/tags/v6.6.0-hardened1`, then re-create).

## 9. Verify the release assets

When the build completes:

```
curl -fsS -H "Authorization: token $RELEASE_TOKEN" \
    https://git.unredacted.org/api/v1/repos/unredacted/linux-hardened-unredacted/releases/tags/v6.6.0-hardened1 \
    | jq '.assets[].name'
```

Expected output: `linux-image-...-hardened-unredacted-amd64_*.deb`, `linux-headers-...-hardened-unredacted-amd64_*.deb`, `final.config`, and (if you built debug) `linux-image-...-hardened-unredacted-amd64-dbg_*.deb`.

## 10. Run publish.yml against the test tag

In the Forgejo Actions UI, manually dispatch `publish.yml`:
- `version`: `v6.6.0-hardened1`
- `distribution`: `trixie`

There is **no `component` input** — one dispatch publishes both components: the workflow splits the `-dbg` package into the `debug` component and everything else into `main`, in a single run.

Watch the workflow. It downloads the `.debs` from the draft release, uploads them to the Debian registry (main + debug), purges Fastly, commits the manifest + `final.config` back to main, and un-drafts the release (step 10a).

Verify the registry:

```
curl -fsS https://repo.unredacted.org/debian/dists/trixie/InRelease | head -20
curl -fsS https://repo.unredacted.org/debian/dists/trixie/main/binary-amd64/Packages | head -20
```

Then dispatch `repro-check.yml` for this tag to verify reproducibility. It is `workflow_dispatch`-only (Forgejo has no `workflow_run` trigger, so it cannot auto-chain off publish); the nightly cron is the backstop. It needs a docker-capable runner.

## 10a. Check that the release was published (un-drafted)

`build-kernel.yml` creates the Forgejo release as a **draft** by design: that is the human review gate before anything becomes public. `publish.yml` un-drafts it as its **last** step, after the registry upload and the manifest commit, so a failure earlier leaves the release a draft rather than announcing a half-published one. The step then fetches `unredacted-hardened.der` without credentials and warns if that is not a 200.

Check the end of the publish run's log for:

```
published release <tag> (id <id>)
anonymous asset fetch OK (200): https://git.unredacted.org/unredacted/linux-hardened-unredacted/releases/download/<tag>/unredacted-hardened.der
```

A release that stays a draft breaks the anonymous download of its assets, which these depend on:

- [../users/secure-boot.md](../users/secure-boot.md) — users `wget` `unredacted-hardened.der` from the release URL to enroll MOK. Without it they cannot boot the kernel they just installed on a Secure Boot machine.
- [../users/verifying-packages.md](../users/verifying-packages.md) — the same download, plus the fingerprint published in the release notes.
- [../users/cve-policy.md](../users/cve-policy.md) — the Forgejo releases RSS feed is the announced CVE-response channel, and drafts do not appear in it.

Confirm it yourself before announcing:

```
curl -sI "https://git.unredacted.org/unredacted/linux-hardened-unredacted/releases/download/$TAG/unredacted-hardened.der" | head -1
```

If the publish run failed before its last step, fix the cause and dispatch `publish.yml` again: every step is idempotent, and the un-draft step does nothing to a release that is already published. To un-draft by hand instead, use **Releases → the draft → Edit → untick "This is a draft" → Update release** in the Forgejo UI, or the API:

```
# Resolve the id from the LIST endpoint, not /releases/tags/{tag}: some Forgejo
# versions filter drafts out of the by-tag lookup and return a null id.
id=$(curl -fsS -H "Authorization: token $RELEASE_TOKEN" \
  "https://git.unredacted.org/api/v1/repos/unredacted/linux-hardened-unredacted/releases?limit=50" \
  | jq -r --arg t "$TAG" '.[] | select(.tag_name==$t) | .id')
curl -fsS -X PATCH -H "Authorization: token $RELEASE_TOKEN" \
  -H "Content-Type: application/json" -d '{"draft":false}' \
  "https://git.unredacted.org/api/v1/repos/unredacted/linux-hardened-unredacted/releases/$id"
```

## 11. Install on a clean Debian 13 VM

Follow [install.md](../users/install.md) literally:

```
sudo install -d -m 0755 /etc/apt/keyrings
sudo wget -O /etc/apt/keyrings/unredacted-hardened.asc https://repo.unredacted.org/debian/repository.key
gpg --show-keys /etc/apt/keyrings/unredacted-hardened.asc
# verify the fingerprint matches what you published in step 2
echo 'deb [signed-by=/etc/apt/keyrings/unredacted-hardened.asc] https://repo.unredacted.org/debian trixie main' \
  | sudo tee /etc/apt/sources.list.d/unredacted-hardened.list
sudo apt update
sudo apt install linux-image-hardened-unredacted-amd64 linux-headers-hardened-unredacted-amd64
```

After install, enroll the signing certificate via MOK by hand — there is no auto-enroll postinst. Download `unredacted-hardened.der` from the draft release, `sudo mokutil --import unredacted-hardened.der`, set the one-time password, reboot, enroll at the firmware prompt, and boot into the hardened kernel. See [../users/secure-boot.md](../users/secure-boot.md).

## 12. Verify everything works

```
uname -r                                              # hardened version
dmesg | grep -E 'tainting|module verification'        # no output
mokutil --sb-state                                    # SecureBoot enabled
mokutil --list-enrolled | grep unredacted             # cert is trusted
```

Bonus check:

```
sudo apt install zfs-dkms
sudo modprobe zfs && lsmod | grep zfs                  # DKMS rebuild + load
```

If any of these fail, that's the first real signal. Investigate, fix, re-test.

## 13. Clean up the test artifacts

If everything passed:

```
# Delete the draft release and stub tag. (gh is GitHub-only and will NOT
# work against Forgejo — use the Forgejo UI, or `tea release delete
# v6.6.0-hardened1` followed by deleting the tag.)

# Remove the manifest commit if it landed (optional; keeping it is fine).
git revert <commit-sha>
git push origin main
```

## 14. You're ready for the first real tag

Push the actual upstream `linux-hardened` tag you intend to ship. Run `publish.yml` once (one dispatch publishes main + debug), then dispatch `repro-check.yml` for the tag. Announce in release notes.

Subscribe to the Forgejo RSS feed yourself, so you see what users see.

## 15. Retention rotation (prune)

As releases accumulate, `main` should hold only the newest few kernels per line; older ones move to the `archive` component (still installable, just not the default). Retention is **per kernel line**: each line in [`configs/lines.toml`](../../configs/lines.toml) keeps its own `keep_in_main` newest cores (the stable line keeps 3), so if more than one line is ever tracked they don't evict each other.

This runs via the **`prune`** workflow (Actions → `prune`), and is **destructive** (it re-uploads old versions to `archive`, then deletes them from `main`). `tools/prune.py` has not yet been exercised against a live registry, so:

1. **Always dry-run first.** Dispatch `prune` with `confirm` left **blank** — that prints the rotation plan (`to_archive_versions`, `packages_to_archive`) and changes nothing. With registry creds present it lists the live registry and shows the real plan.
2. **Review the plan.** Confirm only versions you intend to retire are listed, and that no line you still support is being emptied.
3. **Run for real.** Re-dispatch with `confirm` set to the **exact distribution name** (e.g. `trixie`). Any other value (or blank) stays a dry-run.

The workflow reuses the publish credentials (`REGISTRY_USER`/`REGISTRY_TOKEN`, `FASTLY_*`) — no new secret to provision. Cadence: after a release once a line exceeds its keep window. To **sunset** an old stable line entirely (e.g. once everyone has moved off 7.0), give it a `[[line]]` block with `keep_in_main = 0` in `configs/lines.toml`, dry-run, then rotate.

## When something goes wrong months later

The runbook above is the path through unfamiliar territory once. After that, the `cve-watch.yml` job tells you when upstream moves; you push a matching local tag; CI does the rest. It also tells you when upstream *doesn't* move while kernel.org does; that issue carries a forward-port dry run and the tag to push (see [cve-policy.md](../users/cve-policy.md#forward-ports)). The same failure modes (Debian source version drift, Pangolin/Fastly secret rotation expiry, runner image staleness) will recur. Keep this doc updated when you hit a new one.
