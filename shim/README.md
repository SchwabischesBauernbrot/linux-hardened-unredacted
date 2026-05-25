# Shim build (currently blocked)

> **Status:** This track is blocked. Microsoft's UEFI signing requirements call for HSM-backed signing keys with documented dual-factor authorization. This project's kernel + module signing key lives in Forgejo's secret store, which does not meet that bar. End users on Secure Boot use MOK enrollment indefinitely; see [docs/users/secure-boot.md](../docs/users/secure-boot.md).
>
> The materials in this directory remain as reference. If the project ever acquires an HSM, this track unblocks and the README below applies.

This directory holds the project's UEFI shim build and the materials that would be submitted to the shim-review board if the HSM gate cleared.

The shim is the trust hand-off: UEFI firmware trusts the Microsoft third-party UEFI CA, which signs our shim, which embeds our vendor cert, which signs the hardened kernel. End users on stock Debian/Ubuntu would boot a signed kernel without manual MOK enrollment.

## What's here

| File | Purpose |
| ---- | ------- |
| `Dockerfile` | Reproducible build of `shimx64.efi` from `rhboot/shim` upstream, with our vendor cert embedded |
| `submission/README.md` | Index of materials submitted to the shim-review board |
| `submission/*` | The submission package itself (HSM description, build logs, legal entity confirmation) |

## Status

| State | Reason |
| ----- | ------ |
| **Blocked** | Microsoft requires HSM-backed signing keys. The project signs with a Forgejo-resident key. The shim-review board would reject a submission on this basis. |

The Dockerfile, submission skeleton, and supporting docs remain in place so that if the project ever moves to HSM-backed signing the unblock is mostly a configuration change.

## What would have to change to unblock

1. The project signing key moves to an HSM (YubiHSM 2, Nitrokey HSM 2, cloud KMS, or equivalent).
2. `docs/operators/signing-key-procedures.md` is replaced or augmented with HSM procedures.
3. `SECURITY.md` key custody is rewritten back to the HSM model.
4. `vendor.der` (DER-encoded public cert) is generated and placed at this directory (gitignored).
5. The submission package under `submission/` is filled in.
6. Phasing in the implementation spec is reinstated (Phases 2 and 2.5).

## Microsoft signing requirements that constrain us

Per Microsoft's current UEFI signing requirements:

- HSM-backed signing key with documented security guarantees.
- Dual-factor authorization for signing operations.
- Signing in a physically secured environment.
- Key backup, retention, and destruction procedures documented.

In the unblock scenario, [SECURITY.md](../SECURITY.md) and a (currently absent) `docs/operators/hsm-procedures.md` would carry the narrative the shim-review board reads. The existing [docs/operators/signing-key-procedures.md](../docs/operators/signing-key-procedures.md) covers the Forgejo-secret model, not the HSM model.

## What our shim does and doesn't do

Does:

- Verify the signature on the kernel image about to be loaded.
- Verify signatures on subsequent modules during early boot.
- Hand off to GRUB2 (unmodified Debian/Ubuntu binary).

Does not:

- Boot non-open-source bootloaders.
- Embed any non-cryptographic policy.
- Accept user input during boot beyond MOK Management (and only when the user invokes it).
