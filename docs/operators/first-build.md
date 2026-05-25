# First Phase 1 build: a walkthrough

The first end-to-end build on real infrastructure is where the implicit assumptions get tested. This document walks through every command, in order. Allocate half a day; expect things to fail.

## What you'll have when you're done

A test tag (e.g. `v0.0.0-hardened1`) pushed against a known-small kernel; CI built it, signed it, attached `.debs` to a draft release; you ran `publish.yml` manually; you installed the `.deb` on a clean Debian 13 VM, enrolled MOK, booted the hardened kernel, and confirmed module signature verification.

If any of the above doesn't work, fix what broke before pushing the first real tag.

## Prerequisites

Have these ready before you start:

- A Linux machine with Docker, registered as a Forgejo runner with label `linux-hardened`.
- A Forgejo instance at `git.unredacted.org` with the repo at `unredacted/linux-hardened`.
- A Fastly account (OSS-program application optional but in progress) with a service pointing at `repo.unredacted.org`.
- Pangolin in front of the Forgejo origin.
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

## 2. Generate the apt-repo signing key

In Forgejo's settings for the `unredacted/linux-hardened` package registry, generate the repo signing key. Forgejo handles the GPG generation and key storage internally. Note the fingerprint that's displayed.

Insert the fingerprint into:
- `README.md` (the "TODO: insert apt repo key fingerprint" placeholder)
- `SECURITY.md` (two TODOs about the security PGP key and the canonical fingerprint sources)
- `docs/users/verifying-packages.md` (the TODO about canonical fingerprint sources)

Commit. Publish the fingerprint at https://unredacted.org as well, so users have two out-of-band sources to verify against.

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
| `FORGEJO_USER` | The bot account that will own uploads (e.g. `unredacted-bot`) |
| `FORGEJO_PUBLISH_TOKEN` | Personal access token with `write:package` on owner `unredacted` |
| `FORGEJO_RELEASE_TOKEN` | Token with `write:repository` on `unredacted/linux-hardened` |
| `MANIFEST_COMMIT_TOKEN` | Token with `write:repository` (push to main) on `unredacted/linux-hardened` |
| `FORGEJO_ISSUE_TOKEN` | Token with `write:issue` on `unredacted/linux-hardened` |

Scope each to the workflows that need it (see the table in [runner-setup.md](runner-setup.md)). Don't reuse one token across workflows.

## 5. Configure Fastly

Apply the VCL from [fastly-config.md](fastly-config.md) to the service that serves `repo.unredacted.org`. Coin the `X-Origin-Auth` shared secret (32 bytes of randomness, e.g. `openssl rand -hex 32`), install it in a Fastly Edge Dictionary, and reference it from the VCL's `set req.http.X-Origin-Auth = ...` line.

Add Fastly secrets to Forgejo:

| Secret | Value |
| ------ | ----- |
| `FASTLY_SERVICE_ID` | The service ID from Fastly's UI |
| `FASTLY_PURGE_TOKEN` | API token with `purge_select` permission on this service only |

## 6. Configure Pangolin

In Pangolin's resource config for `git.unredacted.org`:

1. Add a Header Match auth rule on `/api/packages/unredacted/debian/` paths requiring `X-Origin-Auth` to equal the secret from step 5.
2. Add a higher-priority allow rule for PUT/POST on `**/upload` from the runner's egress IP. See [reverse-proxy.md](reverse-proxy.md).

Verify with curl per the verification section of that doc.

## 7. Diff the hardening overlay against upstream

Before building any real kernel, sanity-check the overlay:

```
git clone https://github.com/anthraxx/linux-hardened.git /tmp/lh
cd /tmp/lh
git checkout v6.12.8-hardened1   # or whatever recent tag
# Look at the recommended hardening kconfig fragment in the upstream repo
diff -u /tmp/lh/path/to/recommended-config configs/hardened-overlay.config
```

Reconcile any drift. Upstream occasionally adds or removes hardening symbols across kernel versions.

## 8. Push a stub test tag

Pick a small, well-known kernel to use as a smoke test. v6.6.x LTS is reasonable; v6.12.8-hardened1 (or whatever's current) if you trust the audit.

```
git tag v6.6.0-hardened1 -m "smoke test"
git push origin v6.6.0-hardened1
```

`build-kernel.yml` triggers. Watch the workflow in the Forgejo UI.

**What will probably fail the first time:**

- Some package missing from `containers/Dockerfile.debian-trixie-amd64`. Add it, rebuild the image.
- The Debian source dir name doesn't match what `fetch-distro-source.sh` expects. Look at the error, adjust the version-string parser if needed.
- Pangolin's allow rule for the runner IP isn't quite right; CI uploads 403. Re-check step 6.
- The signing step fails because the secret was loaded with stray whitespace. Re-add the secret without the trailing newline.
- `debian/patches/` was already empty in this kernel version, so the truncate is a no-op. Fine.
- `apt-get source linux=$version` fails because the trixie apt index has rotated to a newer version. Either point at snapshot.debian.org or accept that the pinned version changes per-build.

Each failure is a learning. Fix, push the fix, re-tag if necessary (`git tag -d v6.6.0-hardened1 && git push origin :refs/tags/v6.6.0-hardened1`, then re-create).

## 9. Verify the release assets

When the build completes:

```
curl -fsS -H "Authorization: token $FORGEJO_RELEASE_TOKEN" \
    https://git.unredacted.org/api/v1/repos/unredacted/linux-hardened/releases/tags/v6.6.0-hardened1 \
    | jq '.assets[].name'
```

Expected output: `linux-image-...-hardened-amd64_*.deb`, `linux-headers-...-hardened-amd64_*.deb`, `final.config`, and (if you built debug) `linux-image-...-hardened-amd64-dbg_*.deb`.

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
sudo apt install linux-image-hardened-amd64 linux-headers-hardened-amd64
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
