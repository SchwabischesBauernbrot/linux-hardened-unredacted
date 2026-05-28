# Kernel-config architecture

The build's `.config` is composed at configure time from two committed inputs plus a pinned upstream artifact, never from a single committed full `.config` file. This document explains the model, the trust chain, the operator workflows, and how it differs from the two prior approaches.

## The three inputs

1. **The upstream seed.** A snapshot of anthraxx's Arch `linux-hardened` `config.x86_64`, pinned by sha256 and signed-commit-verified. Lives in `configs/upstream-seed.toml`. Fetched and verified at build time by `build/fetch-seed.sh`. ~12,000 lines representing upstream linux-hardened's idea of a sane hardened kernel for the matching patch revision.

2. **`configs/intent.config`.** Our overlay: ~65 setting lines pinning every hardening symbol POLICY.md positions on. Two layers:
   - **Deltas** (~10 lines): where we deliberately diverge from anthraxx (stricter lockdown forcing, `MODULE_SIG_FORCE`, SHA256+RSA module-signing crypto vs their SHA512+ECDSA, XZ vs ZSTD module compression, latent_entropy off, Docker NAT modules, `USERFAULTFD` kept on with sysctl restriction).
   - **Insurance pins** (~55 lines): every other POLICY-tracked hardening symbol, pinned explicitly even when anthraxx already sets it the same way. Defense-in-depth — a future seed bump cannot silently regress one of these because the fidelity assertion (below) fires the moment one fails to land.

3. **The patched kernel tree.** Upstream Linux at the tagged version plus the linux-hardened patch (`build/fetch-sources.sh` + `build/apply-patches.sh`). Independent of seed/intent; same as in every prior architecture.

## The build flow (`build/configure-kernel.sh`)

```
cp $WORKDIR/upstream-seed.config .config
scripts/kconfig/merge_config.sh -m .config configs/intent.config   # intent over seed
make olddefconfig                                                  # resolve dependencies under our toolchain
<fidelity assertion: every line in configs/intent.config lands in .config or abort>
sed CONFIG_MODULE_SIG_KEY=<runtime tmpfs path>                     # post-fidelity runtime override
```

Fail-fast happens at the fidelity assertion (~2 min after the build container starts), not 30+ min into compile.

## Trust chain

- **Seed integrity.** Two independent checks at build time:
  - `git verify-commit` against anthraxx's pinned key (`E240B57E…`, the same fingerprint we already pin for the linux-hardened patch — see `keys/anthraxx.gpg`). The commit must be signed; the signature must be from the pinned fingerprint.
  - `sha256sum config.x86_64` against the pinned hash in `upstream-seed.toml`. A tampered git server can't substitute different bytes without breaking the hash.
- **Pinning.** The pin is a specific commit hash, not a branch. anthraxx (or anyone) can't move the pin under us by tagging or force-pushing; we only ever build what we explicitly bumped to.
- **Reproducibility.** The release manifest records the full pin (`upstream_seed.{url, commit, config_path, sha256, signer_fpr, signature_verified}`). `tools/repro-check.sh` reads it back and fetches the exact same seed for independent rebuild verification.

## Operator workflows

### Routine kernel-version bump (no seed bump)

Most upstream bumps don't require touching the seed. Tag the new kernel, push:

```
git tag v7.0.11-hardened1
git push origin v7.0.11-hardened1
```

If the seed's pinned config is still compatible with the new kernel tree, the fidelity assertion passes and the build proceeds. Most of the time this is what happens — anthraxx changes `config.x86_64` in only ~1 in 4–5 tags.

If a new kernel introduces a symbol that interacts with one of our intent pins (e.g. renames a dependency), the fidelity assertion aborts at configure with a clear message naming the symbol. You then decide: pin the new symbol in intent.config, or bump the seed to inherit anthraxx's choice.

### Bumping the seed pin

Run periodically (quarterly, or when `tools/reconcile-vs-anthraxx.sh` flags interesting changes):

```
tools/bump-seed.sh 7.0.10.hardened1-1   # or a commit hash
```

This:
- Fetches the repo at that ref.
- Verifies the commit is signed by the pinned signer.
- Computes the new `config.x86_64` sha256.
- Rewrites `configs/upstream-seed.toml`.
- Prints a hardening-relevant diff between old and new seed for the commit message.

Review the diff, update `configs/intent.config` and `POLICY.md` if a new symbol warrants explicit pinning (rare — most diffs are driver/CC_HAS_*/fs noise we don't care about), then commit:

```
git add configs/upstream-seed.toml [configs/intent.config configs/POLICY.md]
git commit -m "seed: bump to <ref> (<commit>)"
```

### Periodic reconciliation check

```
tools/reconcile-vs-anthraxx.sh           # diff vs anthraxx HEAD
tools/reconcile-vs-anthraxx.sh <ref>     # diff vs a specific ref
```

READ-ONLY. Reports which hardening-relevant symbols anthraxx has changed since the pinned seed. Use to decide whether to bump.

### Changing our intent (rare)

When we want to enable a new hardening symbol anthraxx doesn't, or override one of theirs:

1. Add/edit the line in `configs/intent.config`.
2. Add the rationale entry in `configs/POLICY.md`.
3. Push — `validate.yml`'s `intent-matches-policy` job confirms parity between the two files.

The next build's fidelity assertion confirms the change actually lands in `.config`.

## Comparison vs prior architectures

### vs. the original "Debian seed + hardening overlay" model

The original `configure-kernel.sh` fetched Debian's `linux` source package every build, extracted its stock `.config` (for Debian's kernel version, not ours), and merged a fragment (`configs/hardened-overlay.config`) on top. The audit's `SLAB_CANARY` finding came from this: the Debian seed was for 6.12, our tree was 7.0.x; symbols whose dependencies shifted between versions silently disappeared.

This model eliminates that class *for the symbols we pin*: the seed targets the same linux-hardened patch family, and the fidelity assertion (`build/configure-kernel.sh`) catches any `intent.config` symbol that fails to land. Two caveats the original framing glossed over:

- **The seed may lag the kernel version.** anthraxx packages on their own cadence, so the pinned seed is often a point release behind the tree (e.g. a `7.0.9` seed under a `7.0.10` build), and sometimes the matching seed does not exist yet at all. `olddefconfig` reconciles the gap — but only the pinned symbols are *asserted*.
- **Inherited symbols need a separate guard.** Symbols we inherit from the seed rather than pin (the LSMs, `BPF_UNPRIV_DEFAULT_OFF`, etc.) sit outside the fidelity assertion. `tools/check-hardening-drift.sh` (run in `build-kernel.yml`) closes that gap: it fails the build if an enabled hardening symbol regresses versus the most recent released `final.config`. There is deliberately **no** "seed version must equal kernel version" gate — that would fail every build during the normal lag.

### vs. the "committed authoritative config" model (the immediately prior architecture)

The intermediate architecture (commit `7fb8b31`) committed the full final `.config` as `configs/config.debian-trixie-amd64` and did `cp + olddefconfig + diff`. That fixed the silent-drop class but required explicit operator review of every per-kernel-bump drift — manageable in principle, but burdensome under a 48-hour CVE SLA with a small ops team. Worse, it didn't pick up new hardening features upstream linux-hardened adopted.

This model inherits anthraxx's hardening choices automatically (new LSMs, new mainline hardening symbols, whatever they enable). The fidelity assertion still catches regressions on the symbols we explicitly track. The seed pin is bumped deliberately when we choose to adopt upstream's changes, not on every kernel bump.

## When to suspect this model is wrong for a situation

- **You need to ship a kernel for which anthraxx has no seed.** anthraxx tracks roughly upstream's stable cadence. If you need to ship a kernel they haven't packaged (e.g., a brand-new mainline release within hours of upstream), you'll have to either wait for them, or bootstrap a one-off seed from a stock distro config + `intent.config` + olddefconfig.
- **You need a non-x86_64 target.** anthraxx's `config.x86_64` is x86_64-only. The `73946f6` "prepare for multi-arch" commit is scaffolding only. Other arches need an alternate seed source — Phase 2 territory.
- **You need to ship without network at build time.** The seed fetch needs network. Mirror anthraxx's repo to your own Forgejo if upstream availability becomes a concern.

## File reference

| Path | Role |
| ---- | ---- |
| `configs/upstream-seed.toml` | Pin: URL, commit, sha256, signer fpr. |
| `configs/intent.config` | Hardening pins (deltas + insurance). |
| `configs/POLICY.md` | Per-symbol rationale; bidirectional parity with intent.config. |
| `build/fetch-seed.sh` | Network-on step: clone + verify-commit + sha256-check. |
| `build/configure-kernel.sh` | Compose + olddefconfig + fidelity assertion + key override. |
| `tools/bump-seed.sh` | Operator helper to update the pin. |
| `tools/reconcile-vs-anthraxx.sh` | Operator-run drift report vs anthraxx HEAD. |
| `tools/build-manifest.py` | Records the seed pin in `releases/<tag>/manifest.json` as `upstream_seed`. |
| `tools/repro-check.sh` | Reads the historical pin from the manifest for independent rebuild. |
| `.forgejo/workflows/validate.yml` | `intent-matches-policy` job enforcing parity. |
