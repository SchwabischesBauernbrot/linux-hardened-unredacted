# Kernel-config architecture

The build's `.config` is composed at configure time from two committed inputs plus a pinned upstream artifact, never from a single committed full `.config` file. This document explains the model, the trust chain, the operator workflows, and how it differs from the two prior approaches. Which seed, which intent fragments and which naming a build uses are set by its **flavor** ([Flavors](#flavors)): `amd64`, and `pi5` (Raspberry Pi 5).

## The three inputs

1. **The upstream seed.** A full hardened `.config` snapshot (~12,000 lines), pinned by sha256 and fetched + verified at build time by `build/fetch-seed.sh`. The seed is selected **per kernel line** (`configs/seeds/<X.Y>.toml`, chosen by the tag-derived `SERIES`; see [Kernel lines](#kernel-lines-single-stable-line-multi-line-capable)). For the stable line it is anthraxx's Arch `linux-hardened` `config.x86_64`, signed-commit-verified. (`configs/upstream-seed.toml` remains as a back-compat symlink to the stable line's seed.)

2. **The intent fragments.** Our overlay: setting lines pinning every hardening symbol POLICY.md positions on, split into `configs/intent.common.config` (80 lines, every flavor), `configs/intent.x86_64.config` (the 9 x86-only pins: `RANDOMIZE_MEMORY`, `LEGACY_VSYSCALL_NONE`, the `MODIFY_LDT_SYSCALL` off-pin, the PTI/retpoline/rethunk mitigations, CET's `X86_KERNEL_IBT` and `X86_USER_SHADOW_STACK`, and `X86_UMIP`), `configs/intent.v7_2.config` (the 2 symbols that only exist from 7.2: `KMALLOC_PARTITION_CACHES`, `KMALLOC_PARTITION_RANDOM`), `configs/intent.arm64.config` (17, every arm64 flavor) and `configs/intent.pi5.config` (26, the Raspberry Pi 5). The flavor descriptor lists which fragments a build merges, common first: amd64 merges common, x86_64 and v7_2 (the same 91 lines it always had); pi5 merges common, arm64 and pi5 (123). A symbol is pinned by exactly one fragment of a flavor. Two layers, across the fragments:
   - **Deltas**: where we deliberately diverge from anthraxx (stricter lockdown forcing, `MODULE_SIG_FORCE`, SHA256+RSA module-signing crypto, XZ vs ZSTD module compression, latent_entropy off, Docker NAT modules, `USERFAULTFD` compiled out entirely, and the additional hardening beyond anthraxx). What anthraxx selects today is not asserted here — the seed is fetched at build time and is not in this tree; re-read it with `tools/reconcile-vs-anthraxx.sh`.
   - **Insurance pins**: every other POLICY-tracked hardening symbol, pinned explicitly even when anthraxx already sets it the same way. Defense-in-depth — a future seed bump cannot silently regress one of these because the fidelity assertion (below) fires the moment one fails to land.

3. **The patched kernel tree.** Upstream Linux at the tagged version plus the linux-hardened patch (`build/fetch-sources.sh` + `build/apply-patches.sh`). Independent of seed/intent; same as in every prior architecture.

## The build flow (`build/configure-kernel.sh`)

```
cp $WORKDIR/upstream-seed.config .config
scripts/kconfig/merge_config.sh -m .config \
    configs/intent.common.config configs/intent.x86_64.config     # the flavor's fragments, in order, over the seed
make ARCH=<kernel_arch> olddefconfig                              # resolve dependencies under our toolchain
<fidelity assertion: every line of every merged fragment lands in .config or abort>
install signing key -> certs/unredacted-signing.pem              # .config is NOT rewritten
```

Fail-fast happens at the fidelity assertion (~2 min after the build container starts), not 30+ min into compile. The assertion checks the union of the fragments, with its count guards applied per fragment too: an emptied or CRLF-mangled fragment fails even when the union still clears the 60-line floor, and a symbol pinned by two fragments is named rather than reported as a confusing MISS. Because no symbol is pinned twice, the merge order cannot change the result: splitting `intent.config` into two fragments left amd64's `final.config` byte-identical.

## Flavors

A **flavor** is the build axis that changes what the distro target and the kernel line cannot: the source tree, the config seed, the intent fragments, the kernel release name, the boot path and the image signing. Each flavor has one descriptor, `configs/flavors/<flavor>.toml`, and every flavor-dependent decision in `build/*.sh`, `tools/*.sh` and `build-kernel.yml` reads from it instead of switching on `ARCH`. The design, including the planned generic `arm64` flavor, is in [flavors.md](flavors.md). Two exist: `amd64`, and `pi5` (Raspberry Pi's kernel tree for the Pi 5 Tor relays).

**Tags route to flavors.** A release tag belongs to exactly one flavor: the one whose `tag_prefix` it carries in front of the release grammar (`v7.2.15-fwd-v7.2.10-hardened1` is amd64's, `pi5-v6.18.60-fwd-v6.18.56-hardened1` pi5's). `build-kernel.yml` triggers on one tag glob per flavor (`tools/flavors.py tag-globs`; `validate.yml` checks the list matches) and its "resolve flavor" step names the flavor with `tools/flavors.py for-tag`. There is no flavor matrix: every flavor builds in the same amd64 job container, and a flavor of another architecture is cross-compiled (`build/install-flavor-deps.sh` installs the cross toolchain; `configure-kernel.sh` and `build-debs.sh` pass `CROSS_COMPILE` when the host's dpkg architecture is not the flavor's `arch`, and nothing otherwise).

**Test builds.** `build-kernel.yml` can also be dispatched (`workflow_dispatch`) with a `tag` input naming a tag that does not exist. It builds what that tag would build, from the dispatched ref, with a throwaway signing key made in the job: the production signing secrets are never passed to it, the stale-tag guard does not apply, and nothing is attached to a release. Everything else (source and seed verification, fidelity, drift guard, QEMU smoke test, manifest) runs as for a tag. Use it to prove a pipeline change end to end before tagging. Dispatch it from the Actions tab, or with `tea api -X POST -d '{"ref":"<branch>","inputs":{"tag":"<tag>"}}' '/repos/{owner}/{repo}/actions/workflows/build-kernel.yml/dispatches'`.

`tools/flavors.py` is the only reader. Shell consumers call `python3 tools/flavors.py get <flavor> <key>`, and every read validates the descriptor first, so a malformed one stops the build at the first script that reads it. `validate.yml` (`pycompile` job) and `build-kernel.yml`'s "resolve flavor" step both run `tools/flavors.py validate`, which also checks the invariants that span flavors and refuses any value this pipeline cannot build yet.

| Field | amd64 | pi5 | Read by | Meaning |
|---|---|---|---|---|
| `name` | `amd64` | `pi5` | everything | Must equal the file name. Names the meta-packages (`linux-image-hardened-unredacted-<name>`, `…-<X.Y>-<name>`) and the `flavor` recorded in the release manifest. |
| `display_name` | `amd64` | `Raspberry Pi 5` | `build-debs.sh` | How the meta-packages' descriptions name the target ("Hardened Linux kernel image for …"). |
| `arch` | `amd64` | `arm64` | `build-debs.sh`, `fetch-sources.sh`, `install-flavor-deps.sh`, the manifest | dpkg architecture: the `.deb` Architecture field and filename suffix. A build host of another architecture cross-compiles. |
| `kernel_arch` | `x86_64` | `arm64` | `configure-kernel.sh`, `build-debs.sh`, the drift guard | The kernel's `ARCH=`. The drift guard requires both configs' headers to name it. |
| `distro`, `release` | `debian`, `trixie` | `debian`, `trixie` | `fetch-sources.sh`, the manifest | The apt suite the packages are for. `repro-check.sh` refuses to rebuild if these and `arch` no longer match what the manifest recorded. |
| `source` | `kernelorg-tarball` | `rpi-git` | `fetch-sources.sh`, `apply-patches.sh` | `kernelorg-tarball`: the signed kernel.org tarball. `rpi-git`: Raspberry Pi's tree at the commit pinned in `configs/sources/<set>/<X.Y>.toml`, cross-checked against the signed kernel.org tarball of the same version ([Downstream source trees](#downstream-source-trees-rpi-git)). Both apply anthraxx's signed patch. |
| `lines` | `amd64` | `pi5` | `build-debs.sh`, `fetch-seed.sh`, `fetch-sources.sh` | The `configs/lines.toml` line set this flavor builds: the `[[line]]` blocks whose `flavor` is this value (blocks without one are amd64's). Its stable series gets the umbrella metas; its name also places the set's pins. |
| `seed_type` | `arch-git` | `apt-deb` | `fetch-seed.sh` | `arch-git`: a config file at a signed git commit, pinned in `configs/seeds/<X.Y>.toml`. `apt-deb`: the `/boot/config-*` inside a distro's signed kernel `.deb`, pinned in `configs/seeds/<set>/<X.Y>.toml` and verified InRelease signature → Packages hash → `.deb` hash → config hash. |
| `intent` | common, x86_64, v7_2 | common, arm64, pi5 | `configure-kernel.sh`, the drift guard | Intent fragments merged in this order. Must start with `configs/intent.common.config`; each must exist; no symbol pinned twice. |
| `localversion` | `-hardened-unredacted-amd64` | `-hardened-unredacted-pi5` | `build-debs.sh` | Appended to the kernel version to form the kernelrelease, so it is in every concrete package name and `/lib/modules` path. Must never contain an `-rpi` component: Raspberry Pi OS's `z50-raspi-firmware` hook would claim the kernel and overwrite the stock DTBs. |
| `tag_prefix` | `""` | `pi5-` | `build-kernel.yml`, `repro-check.sh`, `publish.yml`, the drift baseline | Prefix in front of the release-tag grammar. amd64 owns the unprefixed `v…` tags; other flavors use `<name>-`. Unique across flavors, and none may begin with another. |
| `image_signing` | `sbsign` | `none` | `sign-debs.sh` | `sbsign` signs vmlinuz for UEFI Secure Boot (and then `required_y` must include `CONFIG_EFI` and `CONFIG_EFI_STUB`); `none` leaves the image unsigned (the Pi firmware has no UEFI Secure Boot, and `sbsign` cannot sign `Image.gz`). Modules are always signed at build time. |
| `required_y` | `CONFIG_X86_64`, `CONFIG_EFI`, `CONFIG_EFI_STUB` | `CONFIG_ARM64`, `CONFIG_ARM64_16K_PAGES`, `CONFIG_ARCH_BCM2835` | `build-debs.sh` | Symbols that must be `=y` before the 30+ minute compile starts. |
| `defaults_package` | `true` | `false` | `build-debs.sh`, `prune.py` | Whether this flavor's build emits `unredacted-hardened-defaults`. Exactly one flavor does: it is `Architecture: all` and versioned from the kernel, so a second line (6.18) would publish a lower version of it into the same suite. The others' image metas depend on it without a version. |
| `boot_package` | `""` | `unredacted-rpi5-boot` | `build-debs.sh`, `build-boot-package.sh`, `prune.py` | Boot-integration package built from `packages/<name>/` alongside the kernel; the image metas depend on it. `unredacted-rpi5-boot` stages each kernel into `/boot/firmware/<kernelrelease>/` and boots it through the Pi firmware's `os_prefix` and tryboot ([install-rpi5.md](../users/install-rpi5.md)). Versioned with the kernel build, and emitted only by the flavor's stable line, so no second line publishes a competing version. Its tool's `KR_SUFFIX` must equal `localversion`. At most one flavor per package. |
| `qemu_smoke` | `false` | `true` | `build-kernel.yml`, `install-flavor-deps.sh` | Boot the built kernel under QEMU before signing (`tools/qemu-smoke.sh`; arm64 only): lockdown, active LSMs, mmap ASLR bits and `mmap_min_addr`, and module-signature enforcement, each checked against the build's own `final.config`. |

**What this pipeline can build** is listed in `tools/flavors.py` (`PIPELINE_SUPPORTS`): either `source`, either `seed_type`, either `image_signing`, a QEMU smoke test (arm64), and the boot package `unredacted-rpi5-boot` (or none). A descriptor asking for anything else fails validation, so a flavor cannot be tagged before its pipeline support exists. A requested smoke test that nothing runs would be a guard that silently does not exist. Widen the set in the change that implements the feature.

**Adding a flavor** means a descriptor, its intent fragment(s) and POLICY entries, a line set in `configs/lines.toml` (blocks with `flavor = "<name>"`), its seed (and, for `rpi-git`, source) pins, and its tag glob in `build-kernel.yml`'s triggers. Lines are keyed on `(set, series)`, so a second flavor may track a series another flavor already has: seed and source pins are per set (`configs/seeds/<set>/<X.Y>.toml`; amd64 keeps the flat `configs/seeds/<X.Y>.toml`), retention is per flavor then line, and the drift baseline is per flavor and line. `tools/pins.py validate` (in `validate.yml`) checks every registered line of a non-amd64 set has well-formed pins. Then dispatch a test build ([above](#flavors)) before cutting the first tag.

### Downstream source trees (`rpi-git`)

Raspberry Pi publishes no signed tags or tarballs, so a `rpi-git` line pins a commit hash (content-addressed: it cannot be moved under us) in `configs/sources/<set>/<X.Y>.toml`, with the branch it came from and the kernel version its Makefile declares. `build/fetch-sources.sh`:

1. shallow-fetches exactly that commit and checks it is the one asked for;
2. checks its Makefile declares the pinned version, with no `EXTRAVERSION`, and that the tag is for that version (a pin bump and the tag that ships it cannot drift);
3. fetches and signature-verifies the kernel.org tarball of the same version, exactly as amd64 does;
4. computes the **downstream delta** (`tools/source-delta.py`: every path where the two trees differ, A/M/D with the downstream file's mode and sha256) and refuses to continue unless it is byte-identical to the committed `configs/sources/<set>/<X.Y>.delta`;
5. archives the tree for `apply-patches.sh`, which extracts it instead of the tarball and applies anthraxx's patch as for amd64 (forward-port mode when the tag says so).

The manifest records the tree (`inputs.source_tree`: url, branch, commit, tree id, version, the delta file and its sha256, and the A/M/D counts). **Bumping the source pin** is a reviewed PR that changes `commit` (and `version`, when Raspberry Pi has merged a new stable release) and regenerates the `.delta`. The delta's diff in that PR is the review: it shows every kernel.org file Raspberry Pi starts or stops touching.

`source-bump.yml` opens that PR, every three hours when Raspberry Pi's branch declares a newer version than the pin, from branch `automated/source-bump-<commit12>`. It runs `tools/bump-source.sh <flavor>`, which you can also run by hand (`--commit <sha>` to pick a commit; the pin's own commit re-derives the committed `.delta` and fails if it does not match). The helper runs `build/fetch-sources.sh`'s checks through the same functions (`build/lib-sources.sh`): it fetches exactly the commit, requires its Makefile to declare the version with an empty EXTRAVERSION, requires a `GOODSIG` from a pinned key on the kernel.org tarball, and runs `tools/source-delta.py` with the build's labels. It also writes the PR description (`tools/source-bump-review.py`), a reading aid for the delta diff:

- paths added to or dropped from the delta;
- for each changed hash, whether Raspberry Pi's own change to the file changed, or only kernel.org's file moved under the same change (it compares `diff(kernel.org old, Raspberry Pi old)` with `diff(kernel.org new, Raspberry Pi new)`);
- every Raspberry Pi-side change in a security-sensitive path (`security/`, `mm/`, `kernel/`, `arch/*/kernel/`, `crypto/`, `drivers/iommu/`, the LSM and credential headers in `include/linux/`, `net/core`, `net/ipv4`, `net/ipv6`), with its diff;
- delta paths kernel.org changed whose Raspberry Pi file did not: a stable change the tree may not carry;
- a dry run of the hardened patch the tag will use, after verifying its signature. That is anthraxx's genuine patch at default fuzz once he has tagged the version, otherwise a forward-port of his newest older tag at `-F0` with the Makefile EXTRAVERSION hunk dropped, as `build/apply-patches.sh` does;
- the tag command (`tools/hardened-tag.sh` picks the tag, with a `.P` when that build exists already).

The workflow never merges or tags. When anthraxx tags the version after the PR opened, it re-runs the helper on the PR's commit and rewrites the description, so the tag advice and dry run follow (`build-kernel.yml` refuses a forward-port of a version he has tagged). It closes the PR when Raspberry Pi moves to a newer version (and opens one for that) or the pin catches up another way. It leaves a branch alone that has no open PR, so closing the PR rejects that commit; delete the branch to re-propose it. Merge, then tag from an up-to-date `main` ([pull before you tag](#routine-kernel-version-bump-no-seed-bump)).

`cve-watch.yml`'s `watch-rpi` job (`tools/rpi-line-watch.sh`) files the same issue the amd64 `watch` job does, one per release: *Upstream Raspberry Pi kernel X.Y.Z available for pi5* once Raspberry Pi's branch declares a version we have not published. Like *Upstream linux-hardened tag vX available*, it says what upstream has and what we last published, lists the CVEs fixed in between, and gives the `git pull` / `git tag` / `git push` and the `tea actions workflows dispatch publish.yml …` to run. Conditional notes cover the rest: **Source pin not bumped yet** (merge the source bump PR first; `build-kernel.yml` refuses a tag the pin does not name), **Forward-port** (anthraxx has not tagged that version), **Replaces a forward-port**, and **Stuck release**. The issue is rewritten when the tag to push or the pin state changes, or the CVE list grows. Both kinds of issue close themselves once `releases/<tag>/` for that version is on `main`, and a newer version's issue closes an older one as superseded. Raspberry Pi moving its default branch to another series is a separate issue.

### Distro seeds (`apt-deb`)

An `apt-deb` seed pin (`configs/seeds/<set>/<X.Y>.toml`, read through `tools/pins.py`) names the archive, suite, component, architecture, package, exact version, the `.deb`'s sha256, the config's path inside it and its sha256, the archive key's fingerprint and the keyring file (`keys/raspberrypi-archive.gpg` for pi5). `build/fetch-seed.sh` verifies `InRelease` with that keyring and requires `GOODSIG` and `VALIDSIG` from exactly that fingerprint, reads everything else from gpg's verified output, checks the `Packages.gz` hash the signed `Release` lists, finds the exact package version there and requires its listed sha256 to equal the pinned one, then checks the downloaded `.deb` and the extracted config. The manifest's `upstream_seed` records the whole pin plus the `InRelease` sha256 and `"type": "apt-deb"` (amd64's arch-git records carry no `type`). Raspberry Pi keeps superseded kernel packages listed in the suite's index, so an old pin stays verifiable for `repro-check.sh`. Bumping it: pick the newer `linux-image-*-rpi-2712` from the index, record its version and sha256, extract and hash its `/boot/config-*`, and re-run the gap comparison of [pi5-inherited-gap-audit.md](pi5-inherited-gap-audit.md) against the previous seed.

## Trust chain

- **Seed integrity.** Two independent checks at build time:
  - `git verify-commit` against anthraxx's pinned key (`E240B57E…`, the same fingerprint we already pin for the linux-hardened patch — see `keys/anthraxx.gpg`). The commit must be signed; the signature must be from the pinned fingerprint.
  - `sha256sum config.x86_64` against the pinned hash in `upstream-seed.toml`. A tampered git server can't substitute different bytes without breaking the hash.
- **Pinning.** The pin is a specific commit hash, not a branch. anthraxx (or anyone) can't move the pin under us by tagging or force-pushing; we only ever build what we explicitly bumped to.
- **Reproducibility.** The release manifest records the full pin (`upstream_seed.{url, commit, config_path, sha256, signer_fpr, signature_verified}`). `tools/repro-check.sh` reads it back and fetches the exact same seed for independent rebuild verification.

## Kernel lines (single stable line, multi-line capable)

The project tracks kernel **lines** — a *line* is a kernel `major.minor` (the `series`, e.g. `7.0`), derived from a build's tag in `build-kernel.yml`. Today we track **one rolling stable line** (7.2; previously 7.0 and 7.1). The machinery below is line-parameterized, so tracking additional lines later is largely a config change rather than a rewrite.

### The registry: `configs/lines.toml`

One `[[line]]` block per tracked line is the single source of truth: `series`, `kind` (exactly one `stable` per line set; a line that has been advanced past stays registered as `previous` so retention remains explicit), `keep_in_main` (prune depth), `seed` (the per-line seed pin path), and the optional `flavor` naming the line set it belongs to (absent means `amd64`; a flavor descriptor's `lines` key names the set it builds). `tools/lines.py` reads it — Python consumers import it; shell consumers call `python3 tools/lines.py <query>` (e.g. `stable-series`, `seed-path 7.0`). Seed selection, meta-package naming, prune buckets, and drift scoping all key off it.

**Advancing the stable line** (e.g. 7.1 → 7.2) is one command, `tools/advance-line.sh 7.2 <anthraxx 7.2 packaging ref>`, reviewed as one PR. It creates `configs/seeds/7.2.toml` (header from `tools/seed-header.tmpl`, pin values written by `tools/bump-seed.sh` after signature verification), refuses unless the ref really is a 7.2-series tag, repoints the `configs/upstream-seed.toml` symlink, demotes the 7.1 block in `configs/lines.toml` to `kind = "previous"`, and appends the 7.2 `stable` block; any failure restores the tree. The old seed file is left at its last same-line pin. `seed-bump.yml` runs the same helper automatically when anthraxx's packaging moves to a new series (a same-file bump there would be a cross-series pin that `validate.yml` rejects — PR #55), so the automated PR is the advance itself. The umbrella meta, prune buckets, and drift scope follow automatically; the first 7.2 build has no same-line drift baseline yet, so the guard *skips* with a visible warning rather than comparing against 7.1.

**Merge an advance together with the first tag of the new series.** Once the advance lands, a 7.1 tag still builds (its seed file is still there) but `build-debs.sh` no longer emits the unversioned umbrella metas for it, so umbrella users would not see a late 7.1 point release until the first 7.2 build publishes. Users on the per-series `…-7.1-amd64` meta stay on 7.1 by design and stop receiving updates unless you keep cutting 7.1 tags; sunset the line with `keep_in_main = 0` once that is no longer wanted.

### Per-line seeds

Each line's seed lives in `configs/seeds/<series>.toml`; `build/fetch-seed.sh` selects it from the tag-derived `SERIES`. The stable line's seed is anthraxx's Arch `config.x86_64`, signed-commit + sha256 verified (see [Trust chain](#trust-chain)) — Arch tracks current stable, so it auto-adopts new mainline hardening anthraxx picks up. `tools/bump-seed.sh` and `seed-bump.yml` keep it current.

**If the tag's series has no seed pin, the build hard-fails.** `fetch-seed.sh` refuses to fall back to another line's seed, because doing so silently turns off *both* safety nets at once: the fidelity assertion still passes (the intent fragments are satisfied by either seed) and the hardening-drift guard finds no same-line baseline in `releases/`, so it skips. The result would be one series' kernel built from another series' config, in a green log. Stand the line up properly instead (`tools/advance-line.sh <X.Y> <ref>` does all three edits), or, when anthraxx has not packaged the series yet, [bridge it](#bridging-a-new-series) (`tools/advance-line.sh <X.Y> --bridge`). For a deliberate one-off cross-series build with none of the bridge's checks, the repo variable **`ALLOW_CROSS_SERIES_SEED=1`** downgrades the failure to a warning — unset it again afterwards, or the next genuine mistake passes silently. Prefer the bridge: it is a reviewed PR scoped to one line, recorded in the manifest, and drift-checked. `cve-watch.yml` checks for the seed before it tells you to tag: when anthraxx tags a series that has no `configs/seeds/<X.Y>.toml` on `main`, the tracking issue says not to tag yet and offers both ways forward, and it updates itself (with a comment) once either PR merges.

### Bridging a new series

anthraxx's hardened *patch* for a new series (`v7.3.5-hardened1`) regularly ships days or weeks before his Arch packaging carries a `config.x86_64` for that series. Waiting leaves users on the previous series for that whole time. A **bridge** stands the new line up on the previous line's config, the seed counterpart of a patch forward-port: the patch is the genuine new-series tag, only the seed is borrowed.

```
git switch main && git pull --ff-only
tools/advance-line.sh 7.3 --bridge
git add configs/lines.toml configs/upstream-seed.toml configs/seeds/7.3.toml
git commit -m "lines: advance stable line 7.2 -> 7.3, bridged on the 7.2 seed"
```

Open that as a PR and merge it together with the first `v7.3.x` tag, as for any [line advance](#the-registry-configslinestoml). It differs from a normal advance in one file: `configs/seeds/7.3.toml` keeps the 7.2 pin's values unchanged (same signed commit and sha256, re-verified by every build) and carries a column-0 `# cross-series-seed:` marker block above them. `tools/lines.py bridge-from 7.3` reads the bridge back. It takes the source series from the pin's `tag`, not from the marker's prose. The script refuses to bridge from a line that is itself bridged.

While the line is bridged:

- **The manifest says so.** `build/fetch-seed.sh` logs a warning and records `"cross_series_from": "7.2"` in the release's `upstream_seed` block.
- **The drift guard still runs.** Until 7.3 has a release of its own, `build-kernel.yml` compares the build against the newest 7.2 release, the config the seed came from, in `check-hardening-drift.sh`'s bridge mode. An enabled 7.2 hardening symbol that 7.3 still defines but turned off fails as a `REGRESSION`, as usual. One that 7.3 no longer defines at all (it scans the tree's `Kconfig` files) is a `REMOVED-UPSTREAM` warning, because there is nothing to pin. Check whether it was renamed. Value symbols (ASLR bits, LSM order, KFENCE interval) must not change, as usual.
- **New symbols are listed for review.** Every hardening symbol 7.3 added (no line at all in the 7.2 baseline) appears as a `NEW-IN-7.3` warning with the value `olddefconfig` gave it. Nobody chose those values; anthraxx's 7.3 config would have. **Read that list before dispatching `publish.yml`**, and pin anything that matters in an intent fragment (a 7.3-only symbol goes in a new `configs/intent.v7_3.config`, like `intent.v7_2.config`) with its `POLICY.md` entry.
- **The fidelity assertion is unchanged.** If 7.3 renamed a symbol we pin, the pin does not land and the build fails at configure time. That is the signal to add the new name.

Once the first bridged build publishes, later 7.3 builds baseline against it like any other line.

**How a bridge ends.** `seed-bump.yml` keeps a bridged stable line current from both sides. While anthraxx's packaging is still on 7.2, a new 7.2 config is proposed as a *bridge refresh* of `configs/seeds/7.3.toml`, and the marker stays. When his packaging reaches 7.3, the next run proposes an ordinary same-line bump. `tools/bump-seed.sh` then drops the marker block (it prints `BRIDGE ENDS`, and the PR body says so). The next 7.3 build drift-checks against the bridged release, so any un-pinned default anthraxx sets differently from what `olddefconfig` chose shows up there for review. If one matters for the release already out, rebuild it as `v7.3.5-hardened1.1`. `validate.yml` rejects a marker left on a same-series pin, and a pin that borrows from a *newer* series.

### How the mechanisms scope per line

- **Meta-packages** (`build/build-debs.sh`): each line emits a versioned `linux-image-hardened-unredacted-<X.Y>-amd64`; the stable line additionally emits the unversioned umbrella `linux-image-hardened-unredacted-amd64`. Both depend directly on the concrete `linux-image-<kernelrelease>` (`=` version), so the umbrella tracks current stable and follows a 7.1 → 7.2 transition automatically. The umbrella must never depend on the per-line meta: it used to, and after each line advance the kernel autoremoval that apt ≥ 3.0 runs during `full-upgrade` deleted the old kernel but kept the old line's unused meta, so `apt full-upgrade` failed with "AutoRemover broke stuff". The comment above the meta-packages in `build-debs.sh` has the details.
- **Retention** (`tools/prune.py`): attributes each package to the flavor that built it (its name ends `-hardened-unredacted-[<X.Y>-]<flavor>`; `unredacted-hardened-defaults` is the `defaults_package` flavor's; `linux-libc-dev`, which every build emits, follows the flavors that have its version), then buckets each flavor's versions by `(major, minor)` with that line's own `keep_in_main`; old minors are retained per line until you retire one by setting `keep_in_main = 0` (explicit sunset).
- **Drift baseline** (`build-kernel.yml` via `tools/flavors.py drift-baseline <flavor> <X.Y>`): scoped to the same flavor and line, so advancing 7.0 → 7.1 doesn't false-fail against a cross-series `final.config`, and a pi5 build will never be compared with an amd64 one. The one cross-line comparison is a [bridged](#bridging-a-new-series) line's first build, against the line its seed came from. The lookup matches release dirs by the flavor's tag prefix and the release-tag grammar, cross-checks each one's manifest `flavor` (manifests from before flavors are amd64), and takes the newest by version. `check-hardening-drift.sh` independently refuses two configs whose headers name a different architecture or line.

### Adding an LTS line later

Arch packages only the current stable line, so an older LTS (e.g. a 6.x LTS) has no current Arch seed. The seed for such a line would come instead from a distro that actively maintains that LTS — e.g. Debian trixie ships the 6.12 LTS, whose complete `/boot/config-*` (extracted from its signed `linux-image` `.deb`, archive-keyring-verified) is a version-matched seed. The `apt-deb` seed type ([Distro seeds](#distro-seeds-apt-deb)) does exactly this; pi5's 6.18 line uses it with Raspberry Pi's archive. Because a distro seed sets different *un-pinned* hardening defaults than anthraxx's, blessing such a line also needs a one-time inherited-gap audit ([`kernel-hardening-checker`](https://github.com/a13xp0p0v/kernel-hardening-checker)) promoting any real gaps into the intent: `configs/intent.common.config` if the position holds on every architecture, the arch fragment otherwise. pi5's is [pi5-inherited-gap-audit.md](pi5-inherited-gap-audit.md).

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

If a new kernel introduces a symbol that interacts with one of our intent pins (e.g. renames a dependency), the fidelity assertion aborts at configure with a clear message naming the symbol. You then decide: pin the new symbol in the right intent fragment, or bump the seed to inherit anthraxx's choice.

### Bumping the seed pin

Run periodically (quarterly, or when `tools/reconcile-vs-anthraxx.sh` flags interesting changes):

```
tools/bump-seed.sh --pin-file configs/seeds/7.1.toml 7.1.4.hardened1-1   # or a commit hash
```

**Pick a commit anthraxx signed.** His packaging repo is shared with the other Arch maintainers, who push rebuilds (pkgrel bumps such as `7.2.15.hardened1-3`) signed with their own keys. `bump-seed.sh` accepts only the pinned key, so on such a commit it fails with `No public key`. That is intended: we do not trust the other maintainers' keys. To find the newest commit that will verify, run:

```
tools/newest-signed-ref.sh --pin-file configs/seeds/7.2.toml origin/HEAD
```

It walks first-parent history back from the ref, prints the first commit signed by the pin file's `signer_fpr`, and lists every newer commit it skipped with the signing key and, if the commit touched it, `CHANGES config.x86_64`. It stops at the current pin, so it prints the pinned commit when nothing newer is signed. It fails, without skipping, on a commit with a *bad* signature from the pinned key, because that is what a forged commit looks like. It only selects a commit: `bump-seed.sh` still runs its own strict check on whatever you pass it. A skipped rebuild that changes `config.x86_64` is a config change we do not adopt until anthraxx signs a commit on top of it; usually rebuilds touch only `PKGBUILD`/`.SRCINFO`.

Always pass `--pin-file` for the line you mean. Without it the default target is the `configs/upstream-seed.toml` symlink, i.e. whichever line is *currently* stable — so a copy-pasted example naming an older series' ref silently rewrites the current line's pin to that series' config. `bump-seed.sh` prints a `SERIES BOUNDARY` warning when a bump crosses lines, but it still performs the rewrite.

This:
- Fetches the repo at that ref.
- Verifies the commit is signed by the pinned signer.
- Computes the new `config.x86_64` sha256.
- Rewrites `configs/upstream-seed.toml`.
- Prints a hardening-relevant diff between old and new seed for the commit message.

Review the diff, update the intent fragment (`configs/intent.common.config`, or `configs/intent.x86_64.config` for an x86-only symbol) and `POLICY.md` if a new symbol warrants explicit pinning (rare — most diffs are driver/CC_HAS_*/fs noise we don't care about), then commit:

```
git add configs/upstream-seed.toml [configs/intent.*.config configs/POLICY.md]
git commit -m "seed: bump to <ref> (<commit>)"
```

### Periodic reconciliation check

```
tools/reconcile-vs-anthraxx.sh           # diff vs anthraxx's latest (origin/HEAD)
tools/reconcile-vs-anthraxx.sh <ref>     # diff vs a specific tag/commit
```

READ-ONLY. Reports which hardening-relevant symbols anthraxx has changed since the pinned seed. Use to decide whether to bump. (The default ref is `origin/HEAD` — anthraxx's latest — not a literal `HEAD`, which after the tool's detached baseline checkout would resolve back to the pinned commit and always report "no change".)

**Automated:** `.forgejo/workflows/seed-bump.yml` runs this comparison daily (and on manual dispatch). It opens a PR only when the config content changes and never a duplicate, so a daily run costs one clone. It first resolves the ref (default `origin/HEAD`, the repo tip) with `tools/newest-signed-ref.sh` to the newest commit anthraxx signed, since the tip is often another maintainer's rebuild (see [Bumping the seed pin](#bumping-the-seed-pin)); the skipped commits and why are logged, raised as a job warning, and included at the top of the PR body. When `config.x86_64` *content* at that commit differs from the pin, it runs `tools/bump-seed.sh` (which re-verifies the commit's GPG signature) and opens a **PR** proposing the bump for review. When anthraxx's tag has moved to a *newer series* than our stable line, it instead runs `tools/advance-line.sh` and the PR is a full stable-line advance (see [Kernel lines](#kernel-lines-single-stable-line-multi-line-capable)). Either way it never merges, and never cuts a kernel tag (those stay human decisions). Requires the `SEED_BUMP_TOKEN` secret (see [runner-setup.md](runner-setup.md)).

### Changing our intent (rare)

When we want to enable a new hardening symbol anthraxx doesn't, or override one of theirs:

1. Add/edit the line in the right fragment: `configs/intent.common.config` if the position holds for every flavor, `configs/intent.<arch>.config` if the symbol only exists on that architecture. A symbol lives in exactly one fragment of a flavor.
2. Add the rationale entry in `configs/POLICY.md` (say so if the pin is architecture-specific).
3. Push — `validate.yml`'s `intent-matches-policy` job confirms parity between POLICY.md and the union of the fragments, and its `pycompile` job runs `tools/flavors.py validate` (no symbol pinned twice within a flavor, no fragment that no flavor merges).

The next build's fidelity assertion confirms the change actually lands in `.config`.

## Comparison vs prior architectures

### vs. the original "Debian seed + hardening overlay" model

The original `configure-kernel.sh` fetched Debian's `linux` source package every build, extracted its stock `.config` (for Debian's kernel version, not ours), and merged a fragment (`configs/hardened-overlay.config`) on top. The audit's `SLAB_CANARY` finding came from this: the Debian seed was for 6.12, our tree was 7.0.x; symbols whose dependencies shifted between versions silently disappeared.

This model eliminates that class *for the symbols we pin*: the seed targets the same linux-hardened patch family, and the fidelity assertion (`build/configure-kernel.sh`) catches any intent symbol that fails to land. Two caveats the original framing glossed over:

- **The seed may lag the kernel version.** anthraxx packages on their own cadence, so the pinned seed is often a point release behind the tree (e.g. a `7.0.9` seed under a `7.0.10` build), and sometimes the matching seed does not exist yet at all. `olddefconfig` reconciles the gap — but only the pinned symbols are *asserted*.
- **Inherited symbols need a separate guard.** Symbols we inherit from the seed rather than pin (the LSMs, `BPF_UNPRIV_DEFAULT_OFF`, etc.) sit outside the fidelity assertion. `tools/check-hardening-drift.sh` (run in `build-kernel.yml`) closes that gap: it fails the build if an enabled hardening symbol regresses versus the most recent released `final.config` of the same flavor and line. It also compares four hardening **value** symbols that no `=y`/`=m` comparison can see: `ARCH_MMAP_RND_BITS`, `ARCH_MMAP_RND_COMPAT_BITS`, `LSM` and `KFENCE_SAMPLE_INTERVAL`. Any change in one fails, in either direction, and so does it appearing or disappearing; this applies even to a value an intent fragment pins, so a deliberate change to the pin needs the override once too. (An arm64 test build lost `BPF_LSM` and dropped `ARCH_MMAP_RND_BITS` from 32 to 18 while the old guard saw nothing.) There is deliberately **no** "seed version must equal kernel version" gate — that would fail every build during the normal lag. On a drift failure the step prints the regressed symbol(s) or changed value(s); the operator either pins the symbol in the right intent fragment (plus a `POLICY.md` rationale entry) if it's a real regression, or — for a reviewed, intentional drop or change — re-runs with the repo variable / env `ALLOW_HARDENING_REGRESSION=1`, after which that release's `final.config` becomes the new baseline.

### vs. the "committed authoritative config" model (the immediately prior architecture)

The intermediate architecture (commit `7fb8b31`) committed the full final `.config` as `configs/config.debian-trixie-amd64` and did `cp + olddefconfig + diff`. That fixed the silent-drop class but required explicit operator review of every per-kernel-bump drift — manageable in principle, but burdensome under a 48-hour CVE SLA with a small ops team. Worse, it didn't pick up new hardening features upstream linux-hardened adopted.

This model inherits anthraxx's hardening choices automatically (new LSMs, new mainline hardening symbols, whatever they enable). The fidelity assertion still catches regressions on the symbols we explicitly track. The seed pin is bumped deliberately when we choose to adopt upstream's changes, not on every kernel bump.

## Open decision: activating LoadPin

`configs/intent.common.config` pins `CONFIG_SECURITY_LOADPIN=y`, `CONFIG_SECURITY_LOADPIN_ENFORCE=y`, and `CONFIG_SECURITY_SAFESETID=y`, but none of them appears in `CONFIG_LSM` — so the kernel compiles them in and never initialises them. They enforce nothing today. `configs/POLICY.md`'s `CONFIG_LSM` entry states this explicitly; the pins exist so the symbols cannot silently vanish across a seed bump, and so activating them later is a one-line edit.

Turning LoadPin on is a **feature with a rollout**, not a config tidy-up. With `LOADPIN_ENFORCE=y` the kernel pins kernel-file loads (modules, firmware) to the filesystem of the first such load and refuses any from elsewhere; with `MODULE_SIG_FORCE=y` also set there is no soft-fail path. On user hardware we do not control — initramfs→root transitions, a separate `/usr`, firmware or modules on a distinct mount, DKMS modules built after boot — the failure mode ranges from a module refusing to load to an unbootable system.

Preconditions before enabling:

- A boot matrix covering: plain root-fs modules; initramfs→root transition; separate `/usr`; a DKMS module built and loaded post-boot; a firmware load; rescue boot.
- A `docs/users/incompatibilities.md` entry describing the symptom and the escape.
- A release-note warning, since it changes runtime behaviour on existing installs.
- `loadpin` only. SafeSetID additionally needs a userspace policy to do anything, so activating it without one buys nothing.

Editing `CONFIG_LSM` to activate LoadPin also trips the drift guard's value comparison on the first build after (`CONFIG_LSM` is one of its four value symbols), so that build needs `ALLOW_HARDENING_REGRESSION=1` as the reviewed acknowledgement; the fidelity assertion holds the new value from then on.

## When to suspect this model is wrong for a situation

- **You need to ship a kernel for which Arch has no current seed.** Arch packages only the current stable line. An older LTS line would be seeded from the distro that maintains it (not wired in today — see [Adding an LTS line later](#adding-an-lts-line-later)). For a brand-new mainline release within hours of upstream (before anthraxx packages it), you'll have to wait for them or bootstrap a one-off seed. (A newer *point* release on the same line is different: the seed is per line, so a [forward-port](../users/cve-policy.md#forward-ports) builds with the line's existing seed and needs nothing here.)
- **You need a non-x86_64 target.** anthraxx's `config.x86_64` is x86_64-only. Another architecture needs its own flavor ([Flavors](#flavors)): a descriptor, a distro seed (`seed_type = "apt-deb"`), an intent fragment, and a one-time inherited-gap audit, as pi5 has ([pi5-inherited-gap-audit.md](pi5-inherited-gap-audit.md)).
- **You need to ship without network at build time.** The seed fetch needs network. Mirror anthraxx's repo to your own Forgejo if upstream availability becomes a concern.

## File reference

| Path | Role |
| ---- | ---- |
| `configs/lines.toml` | Registry of tracked kernel lines (series, kind, keep_in_main, seed). |
| `tools/lines.py` | Reads `lines.toml`; importable + a CLI for shell consumers. |
| `configs/seeds/<X.Y>.toml` | Per-line seed pin (the stable line's anthraxx Arch seed). |
| `configs/upstream-seed.toml` | Back-compat symlink to the stable line's seed pin. |
| `configs/flavors/<flavor>.toml` | Build-flavor descriptor (see [Flavors](#flavors)). |
| `tools/flavors.py` | Reads and validates the descriptors; finds the drift baseline. |
| `configs/intent.common.config` | Hardening pins every flavor ships (deltas + insurance). |
| `configs/intent.x86_64.config` | The x86-only hardening pins. |
| `configs/POLICY.md` | Per-symbol rationale; bidirectional parity with the intent fragments. |
| `build/fetch-seed.sh` | Network-on step: clone + verify-commit + sha256-check. |
| `build/configure-kernel.sh` | Compose (seed + the flavor's fragments) + olddefconfig + fidelity assertion + key install. |
| `tools/check-hardening-drift.sh` | Same-flavor, same-line drift guard: enabled hardening symbols and four value symbols. Bridge mode (`DRIFT_BRIDGE_FROM`) for a bridged line's first build. |
| `tools/bump-seed.sh` | Operator helper to update the pin; drops a bridge's marker when it ends one. |
| `tools/advance-line.sh` | Stands up a new stable line; `--bridge` does so on the previous line's seed. |
| `tools/newest-signed-ref.sh` | Resolves an anthraxx ref to the newest commit signed by the pinned key (skips other maintainers' rebuilds). |
| `tools/bump-source.sh` | Moves an `rpi-git` source pin to Raspberry Pi's tip, regenerates its `.delta`, writes the PR's review summary (`tools/source-bump-review.py`); `source-bump.yml` runs it. |
| `build/lib-sources.sh` | Fetch-and-verify functions `fetch-sources.sh`, `apply-patches.sh` and `bump-source.sh` share. |
| `tools/hardened-tag.sh` | The tag that builds a kernel version: genuine, or a forward-port of anthraxx's newest older tag. |
| `tools/reconcile-vs-anthraxx.sh` | Operator-run drift report vs anthraxx HEAD. |
| `tools/build-manifest.py` | Records the seed pin in `releases/<tag>/manifest.json` as `upstream_seed`. |
| `tools/repro-check.sh` | Reads the historical pin from the manifest for independent rebuild. |
| `.forgejo/workflows/validate.yml` | `intent-matches-policy` job enforcing parity. |
