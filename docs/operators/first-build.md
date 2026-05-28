# First Phase 1 build: a walkthrough

The first end-to-end build on real infrastructure is where the implicit assumptions get tested. This document walks through every command, in order. Allocate half a day; expect things to fail.

## What you'll have when you're done

A test tag (e.g. `v0.0.0-hardened1`) pushed against a known-small kernel; CI built it, signed it, attached `.debs` to a draft release; you ran `publish.yml` manually; you installed the `.deb` on a clean Debian 13 VM, enrolled MOK, booted the hardened kernel, and confirmed module signature verification.

If any of the above doesn't work, fix what broke before pushing the first real tag.

## Prerequisites

Have these ready before you start:

- A Linux machine with Docker, registered as a Forgejo runner with label `linux-hardened`.
- A Forgejo instance at `git.unredacted.org` with the repo at `unredacted/linux-hardened`.
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
| `RELEASE_TOKEN` | Token with `write:repository` on `unredacted/linux-hardened` |
| `MANIFEST_COMMIT_TOKEN` | Token with `write:repository` (push to main) on `unredacted/linux-hardened` |
| `ISSUE_TOKEN` | Token with `write:issue` on `unredacted/linux-hardened` |

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

## 7. Reconcile the authoritative config against upstream

Per kernel-version bump, `build/configure-kernel.sh`'s drift check aborts at configure time if `olddefconfig` changes the authoritative config (`configs/config.debian-trixie-amd64`) — meaning upstream added new symbols, flipped defaults, or removed something. The fix workflow is:

```
# Inspect linux-hardened's defaults for the version you're shipping.
git clone https://github.com/anthraxx/linux-hardened.git /tmp/lh
cd /tmp/lh && git checkout v7.0.10-hardened1
# Either: let the build abort, then promote this run's final.config
# (tools/promote-config.sh <tag>), inspect the diff, commit, re-tag.
# Or: pin the affected symbols explicitly in configs/config.debian-trixie-amd64
# first so olddefconfig can't move them.
```

The `policy-matches-config` CI check (`.forgejo/workflows/validate.yml`) enforces that every kconfig assertion in `configs/POLICY.md` holds in the authoritative — update both together when changing one. The authoritative was last refreshed from `v7.0.10-hardened1.3`'s final.config.

## 8. Push a stub test tag

Pick a small, well-known kernel to use as a smoke test. v6.6.x LTS is reasonable; v6.12.8-hardened1 (or whatever's current) if you trust the audit.

```
git tag v6.6.0-hardened1 -m "smoke test"
git push origin v6.6.0-hardened1
```

`build-kernel.yml` triggers. Watch the workflow in the Forgejo UI.

**What will probably fail the first time:**

- Some package missing from `containers/Dockerfile.debian-trixie-amd64`. Add it, rebuild the image.
- The configure step's drift check aborts because `olddefconfig` changed something — inspect the diff in the step log, run `tools/promote-config.sh <tag>` once you're satisfied with the new authoritative, commit, re-tag.
- Pangolin's allow rule for the runner IP isn't quite right; CI uploads 403. Re-check step 6.
- The signing step fails because the secret was loaded with stray whitespace. Re-add the secret without the trailing newline.
- `debian/patches/` was already empty in this kernel version, so the truncate is a no-op. Fine.
- `apt-get source linux=$version` fails because the trixie apt index has rotated to a newer version. Either point at snapshot.debian.org or accept that the pinned version changes per-build.

Each failure is a learning. Fix, push the fix, re-tag if necessary (`git tag -d v6.6.0-hardened1 && git push origin :refs/tags/v6.6.0-hardened1`, then re-create).

## 9. Verify the release assets

When the build completes:

```
curl -fsS -H "Authorization: token $RELEASE_TOKEN" \
    https://git.unredacted.org/api/v1/repos/unredacted/linux-hardened/releases/tags/v6.6.0-hardened1 \
    | jq '.assets[].name'
```

Expected output: `linux-image-...-hardened-unredacted-amd64_*.deb`, `linux-headers-...-hardened-unredacted-amd64_*.deb`, `final.config`, and (if you built debug) `linux-image-...-hardened-unredacted-amd64-dbg_*.deb`.

## 10. Run publish.yml against the test tag

In the Forgejo Actions UI, manually dispatch `publish.yml`:
- `version`: `v6.6.0-hardened1`
- `component`: `main`
- `distribution`: `trixie`

Watch the workflow. It downloads the `.debs` from the draft release, uploads them to the Debian registry, purges Fastly, and commits the manifest + `final.config` back to main.

Verify the registry:

```
curl -fsS https://repo.unredacted.org/debian/dists/trixie/InRelease | head -20
curl -fsS https://repo.unredacted.org/debian/dists/trixie/main/binary-amd64/Packages | head -20
```

If you also built `-dbg`, dispatch `publish.yml` again with `component=debug`.

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

During install, set a one-time MOK password. Reboot, enroll the MOK at the firmware prompt, boot into the hardened kernel.

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
# Delete the draft release and stub tag.
gh release delete v6.6.0-hardened1 -y --cleanup-tag
# Or via the Forgejo UI.

# Remove the manifest commit if it landed (optional; keeping it is fine).
git revert <commit-sha>
git push origin main
```

## 14. You're ready for the first real tag

Push the actual upstream `linux-hardened` tag you intend to ship. Run `publish.yml` twice (main, then debug). Announce in release notes.

Subscribe to the Forgejo RSS feed yourself, so you see what users see.

## When something goes wrong months later

The runbook above is the path through unfamiliar territory once. After that, the `cve-watch.yml` job tells you when upstream moves; you push a matching local tag; CI does the rest. The same failure modes (Debian source version drift, Pangolin/Fastly secret rotation expiry, runner image staleness) will recur. Keep this doc updated when you hit a new one.
