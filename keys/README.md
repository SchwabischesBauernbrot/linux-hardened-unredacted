# Pinned upstream keys

This directory holds the public GPG keys used by `build/fetch-sources.sh` to verify upstream tarballs and patches. Each key file is a binary keyring (no armor) so `gpg --import` accepts it directly.

A key change in this directory is a trust-boundary change. Any commit that adds, replaces, or removes a key must justify the change in the commit message and reference the canonical out-of-band source for the new fingerprint.

## Files

| File | Identity | Used to verify | Source for the fingerprint |
| ---- | -------- | -------------- | -------------------------- |
| `kernel-org.gpg` | Greg Kroah-Hartman (`647F28654894E3BD457199BE38DBBDC86092693E`) | Stable kernel.org tarball signatures | https://kernel.org/category/signatures.html and https://kernel.org/pub/linux/kernel/people/gregkh/Greg_Kroah-Hartman_pubkey.asc |
| `anthraxx.gpg` | Levente Polyak / anthraxx (`E240B57E2C4630BA768E2F26FC1B547C8D8172C8`) | linux-hardened patch signatures | Arch Linux PKGBUILD `validpgpkeys=`; Alpine APKBUILD; the linux-hardened release `.sig` files themselves |

### Why kernel-org.gpg holds only Greg KH and not Linus

kernel.org splits signing by release type. Mainline tarballs (`linux-X.Y.tar.xz`, no third version segment) are signed by Linus Torvalds. Stable tarballs (`linux-X.Y.Z.tar.xz`, three-segment versions) are signed by Greg KH. This project follows `linux-hardened`, which only tags against stable releases — the tag format is `vX.Y.Z-hardenedN` and the `Z` is required. Every tarball this pipeline fetches is therefore a stable release signed by Greg KH.

Linus's PGP key (`ABAF11C65A2970B130ABE3C479BE3E4300411886`) is also progressively harder to retrieve from public keyservers, which makes pinning it fragile. We don't pin what we don't use. If the project ever needs to build a mainline `.0` release, add the Linus key in a separate commit and lift the stable-only restriction here.

## Adding the kernel.org keys

```
gpg --no-default-keyring --keyring ./keys/kernel-org.gpg --recv-keys \
    647F28654894E3BD457199BE38DBBDC86092693E

# verify fingerprint matches the canonical source before committing
gpg --no-default-keyring --keyring ./keys/kernel-org.gpg --fingerprint
```

A clean fingerprint match against both kernel.org's published signatures page and Greg KH's own keyserver is the minimum bar.

## Adding the anthraxx maintainer key

```
gpg --no-default-keyring --keyring ./keys/anthraxx.gpg --recv-keys \
    E240B57E2C4630BA768E2F26FC1B547C8D8172C8

# verify the full fingerprint
gpg --no-default-keyring --keyring ./keys/anthraxx.gpg --fingerprint
```

Compare the printed fingerprint against:

1. Arch Linux's [`linux-hardened` PKGBUILD](https://gitlab.archlinux.org/archlinux/packaging/packages/linux-hardened/-/blob/main/PKGBUILD) `validpgpkeys=` field.
2. The Alpine `linux-hardened` APKBUILD if Alpine is currently shipping a hardened kernel.
3. The maintainer's own publication (e.g. social account, Keyoxide).

All three must agree. A divergence is either a stale source or a compromise.

### Note on key expiry

GitHub's UI labels the maintainer key as expired. That label refers to the key's ability to assert *new* identity bindings or sign *new* artifacts; it does not invalidate signatures made during the key's validity window. GnuPG verifies such signatures and emits the status `EXPKEYSIG` instead of `GOODSIG`. `build/fetch-sources.sh` treats both as success and records the expiry in the verify log for the build manifest.

If the maintainer publishes a renewed or replacement key, swap this file in a single commit and update the fingerprint in this table.

## Rotation

If a pinned key rotates upstream:

1. Verify the new fingerprint against at least two independent out-of-band sources.
2. Replace the file in a single commit.
3. Note the rotation in the commit message and the next release notes.

Never trust an "automatic" key update; the verification step is the entire point.
