# Kernel-config architecture

The build's `.config` is composed at configure time from two committed inputs plus a pinned upstream artifact, never from a single committed full `.config` file. This document explains the model, the trust chain, the operator workflows, and how it differs from the two prior approaches.

## The three inputs

1. **The upstream seed.** A full hardened `.config` snapshot (~12,000 lines), pinned by sha256 and fetched + verified at build time by `build/fetch-seed.sh`. The seed is selected **per kernel line** (`configs/seeds/<X.Y>.toml`, chosen by the tag-derived `SERIES`; see [Kernel lines](#kernel-lines-single-stable-line-multi-line-capable)). For the stable line it is anthraxx's Arch `linux-hardened` `config.x86_64`, signed-commit-verified. (`configs/upstream-seed.toml` remains as a back-compat symlink to the stable line's seed.)

2. **`configs/intent.config`.** Our overlay: 92 setting lines pinning every hardening symbol POLICY.md positions on. Two layers:
   - **Deltas** (17 lines): where we deliberately diverge from anthraxx (stricter lockdown forcing, `MODULE_SIG_FORCE`, SHA256+RSA module-signing crypto vs their SHA512+ECDSA, XZ vs ZSTD module compression, latent_entropy off, Docker NAT modules, `USERFAULTFD` kept on with sysctl restriction).
   - **Insurance pins** (75 lines): every other POLICY-tracked hardening symbol, pinned explicitly even when anthraxx already sets it the same way. Defense-in-depth — a future seed bump cannot silently regress one of these because the fidelity assertion (below) fires the moment one fails to land.

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

## Kernel lines (single stable line, multi-line capable)

The project tracks kernel **lines** — a *line* is a kernel `major.minor` (the `series`, e.g. `7.0`), derived from a build's tag in `build-kernel.yml`. Today we track **one rolling stable line** (7.0, advancing to 7.1). The machinery below is line-parameterized, so tracking additional lines later is largely a config change rather than a rewrite.

### The registry: `configs/lines.toml`

One `[[line]]` block per tracked line is the single source of truth: `series`, `kind` (exactly one `stable`), `keep_in_main` (prune depth), and `seed` (the per-line seed pin path). `tools/lines.py` reads it — Python consumers import it; shell consumers call `python3 tools/lines.py <query>` (e.g. `stable-series`, `seed-path 7.0`). Seed selection, meta-package naming, prune buckets, and drift scoping all key off it.

**Advancing the stable line** (7.0 → 7.1) is one reviewed edit: add `configs/seeds/7.1.toml` (via `tools/bump-seed.sh --pin-file configs/seeds/7.1.toml <7.1-arch-ref>`), repoint the `configs/upstream-seed.toml` symlink to it, and change the block's `series` + `seed`. The umbrella meta, prune buckets, and drift scope follow automatically; the first 7.1 build has no same-line drift baseline yet, so the guard correctly *skips* rather than comparing against 7.0.

### Per-line seeds

Each line's seed lives in `configs/seeds/<series>.toml`; `build/fetch-seed.sh` selects it from the tag-derived `SERIES`. The stable line's seed is anthraxx's Arch `config.x86_64`, signed-commit + sha256 verified (see [Trust chain](#trust-chain)) — Arch tracks current stable, so it auto-adopts new mainline hardening anthraxx picks up. `tools/bump-seed.sh` and `seed-bump.yml` keep it current.

### How the mechanisms scope per line

- **Meta-packages** (`build/build-debs.sh`): each line emits a versioned `linux-image-hardened-unredacted-<X.Y>-amd64`; the stable line additionally emits the unversioned umbrella `linux-image-hardened-unredacted-amd64` (Depends `>=` the stable versioned meta), so the umbrella tracks current stable and follows a 7.0 → 7.1 transition automatically.
- **Retention** (`tools/prune.py`): buckets by `(major, minor)` with each line's own `keep_in_main`; old minors are retained per line until you retire one by setting `keep_in_main = 0` (explicit sunset).
- **Drift baseline** (`build-kernel.yml`): scoped to the same line, so advancing 7.0 → 7.1 doesn't false-fail against a cross-series `final.config`.

### Adding an LTS line later

Arch packages only the current stable line, so an older LTS (e.g. a 6.x LTS) has no current Arch seed. The seed for such a line would come instead from a distro that actively maintains that LTS — e.g. Debian trixie ships the 6.12 LTS, whose complete `/boot/config-*` (extracted from its signed `linux-image` `.deb`, archive-keyring-verified) is a version-matched seed. Standing this up means reintroducing a second seed source in `fetch-seed.sh` (a `seed_type` dispatch) plus a small pin helper — deferred until an LTS line is actually wanted (the full design lives in the project plan and git history). Because a distro seed sets different *un-pinned* hardening defaults than anthraxx's, blessing such a line also needs a one-time inherited-gap audit ([`kernel-hardening-checker`](https://github.com/a13xp0p0v/kernel-hardening-checker)) promoting any real gaps into the shared `configs/intent.config`.

## Operator workflows

### Routine kernel-version bump (no seed bump)

Most upstream bumps don't require touching the seed. Tag the new kernel, push:

```
git switch main && git pull --ff-only
git tag v7.0.11-hardened1
git push origin v7.0.11-hardened1
```

**Pull before you tag.** `main` moves without you: `seed-bump.yml` opens PRs that get merged, and every successful build appends a `publish: <tag>` commit with the release manifest. A tag cut from a stale checkout is a valid tag on an old commit — the build succeeds, but against the *previous* seed pin, and nothing in the pipeline complains. `--ff-only` is deliberate: if the pull isn't a fast-forward you have local commits and should sort that out before tagging a release.

If you notice after pushing, delete the tag on both sides and re-cut it — the tag push is the only build trigger, so re-tagging re-runs the build:

```
git push origin :refs/tags/v7.0.11-hardened1
git tag -d v7.0.11-hardened1
git pull --ff-only
git tag v7.0.11-hardened1 && git push origin v7.0.11-hardened1
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
tools/reconcile-vs-anthraxx.sh           # diff vs anthraxx's latest (origin/HEAD)
tools/reconcile-vs-anthraxx.sh <ref>     # diff vs a specific tag/commit
```

READ-ONLY. Reports which hardening-relevant symbols anthraxx has changed since the pinned seed. Use to decide whether to bump. (The default ref is `origin/HEAD` — anthraxx's latest — not a literal `HEAD`, which after the tool's detached baseline checkout would resolve back to the pinned commit and always report "no change".)

**Automated:** `.forgejo/workflows/seed-bump.yml` runs this comparison weekly (and on manual dispatch). When anthraxx's `config.x86_64` *content* changes, it runs `tools/bump-seed.sh` (which verifies the commit's GPG signature) and opens a **PR** proposing the bump for review — it never merges, and never cuts a kernel tag (those stay human decisions). Requires the `SEED_BUMP_TOKEN` secret (see [runner-setup.md](runner-setup.md)).

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
- **Inherited symbols need a separate guard.** Symbols we inherit from the seed rather than pin (the LSMs, `BPF_UNPRIV_DEFAULT_OFF`, etc.) sit outside the fidelity assertion. `tools/check-hardening-drift.sh` (run in `build-kernel.yml`) closes that gap: it fails the build if an enabled hardening symbol regresses versus the most recent released `final.config`. There is deliberately **no** "seed version must equal kernel version" gate — that would fail every build during the normal lag. On a drift failure the step prints the regressed symbol(s); the operator either pins the symbol in `intent.config` (plus a `POLICY.md` rationale entry) if it's a real regression, or — for a reviewed, intentional drop — re-runs with the repo variable / env `ALLOW_HARDENING_REGRESSION=1`, after which that release's `final.config` becomes the new baseline.

### vs. the "committed authoritative config" model (the immediately prior architecture)

The intermediate architecture (commit `7fb8b31`) committed the full final `.config` as `configs/config.debian-trixie-amd64` and did `cp + olddefconfig + diff`. That fixed the silent-drop class but required explicit operator review of every per-kernel-bump drift — manageable in principle, but burdensome under a 48-hour CVE SLA with a small ops team. Worse, it didn't pick up new hardening features upstream linux-hardened adopted.

This model inherits anthraxx's hardening choices automatically (new LSMs, new mainline hardening symbols, whatever they enable). The fidelity assertion still catches regressions on the symbols we explicitly track. The seed pin is bumped deliberately when we choose to adopt upstream's changes, not on every kernel bump.

## When to suspect this model is wrong for a situation

- **You need to ship a kernel for which Arch has no current seed.** Arch packages only the current stable line. An older LTS line would be seeded from the distro that maintains it (not wired in today — see [Adding an LTS line later](#adding-an-lts-line-later)). For a brand-new mainline release within hours of upstream (before anthraxx packages it), you'll have to wait for them or bootstrap a one-off seed.
- **You need a non-x86_64 target.** anthraxx's `config.x86_64` is x86_64-only. The `73946f6` "prepare for multi-arch" commit is scaffolding only. Other arches need an alternate seed source — Phase 2 territory.
- **You need to ship without network at build time.** The seed fetch needs network. Mirror anthraxx's repo to your own Forgejo if upstream availability becomes a concern.

## File reference

| Path | Role |
| ---- | ---- |
| `configs/lines.toml` | Registry of tracked kernel lines (series, kind, keep_in_main, seed). |
| `tools/lines.py` | Reads `lines.toml`; importable + a CLI for shell consumers. |
| `configs/seeds/<X.Y>.toml` | Per-line seed pin (the stable line's anthraxx Arch seed). |
| `configs/upstream-seed.toml` | Back-compat symlink to the stable line's seed pin. |
| `configs/intent.config` | Hardening pins (deltas + insurance). |
| `configs/POLICY.md` | Per-symbol rationale; bidirectional parity with intent.config. |
| `build/fetch-seed.sh` | Network-on step: clone + verify-commit + sha256-check. |
| `build/configure-kernel.sh` | Compose + olddefconfig + fidelity assertion + key override. |
| `tools/bump-seed.sh` | Operator helper to update the pin. |
| `tools/reconcile-vs-anthraxx.sh` | Operator-run drift report vs anthraxx HEAD. |
| `tools/build-manifest.py` | Records the seed pin in `releases/<tag>/manifest.json` as `upstream_seed`. |
| `tools/repro-check.sh` | Reads the historical pin from the manifest for independent rebuild. |
| `.forgejo/workflows/validate.yml` | `intent-matches-policy` job enforcing parity. |
