# Secure Boot

The hardened kernel and its modules are signed by the project's kernel + module signing key. UEFI Secure Boot only loads the kernel once that key is trusted by the firmware.

End users on Secure Boot trust the key by enrolling it via **MOK** (Machine Owner Key). There is no Microsoft-signed shim path; the bottom of this page explains why.

This flow is the same on Debian and Ubuntu. Ubuntu's shim (≥ 15.4) refuses to *boot* a kernel signed by a key carrying the kernel's "module-signing only" usage OID — that's how it stops auto-generated DKMS keys from authorizing kernels — but our signing certificate is a plain code-signing cert with no such OID, so shim accepts it for boot once enrolled. (Ubuntu apt source: [install-ubuntu.md](install-ubuntu.md).)

## Detecting whether you need to do anything

```
mokutil --sb-state
```

- `SecureBoot disabled`: no Secure Boot, nothing to do.
- `SecureBoot enabled`: follow the MOK enrollment flow below.

## MOK enrollment

Installing the hardened kernel places our signing certificate at `/var/lib/shim-signed/mok/unredacted-hardened.der` and queues it for MOK enrollment via `mokutil --import`. You're prompted for a one-time password during `apt install`.

1. During `apt install`, set a one-time MOK password. You'll use it once, in the next minute.
2. Reboot.
3. The firmware shows a blue "MOK Management" screen. It times out and boots the old kernel if you don't interact.
4. Select **Enroll MOK → Continue → Yes → enter the password from step 1 → Reboot**.
5. Boot completes. The signing certificate is trusted by the firmware.

Subsequent kernel updates require no re-enrollment as long as we sign with the same key. Signing-key rotation is announced in release notes and surfaces another MOK prompt.

### If you missed the MOK prompt

Re-queue the enrollment by hand:

```
sudo mokutil --import /var/lib/shim-signed/mok/unredacted-hardened.der
sudo reboot
```

`mokutil` prompts for a one-time password the same way the install hook does.

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| Kernel doesn't appear in GRUB | Initramfs generation failed during install | `sudo update-initramfs -k all -u && sudo update-grub` |
| Boot fails with a Secure Boot error ("Security Violation" / "Access Denied" / bad signature) | Firmware doesn't trust our signing key (MOK not enrolled) | Re-run MOK enrollment above |
| Post-boot, modules fail with `module verification failed` in `dmesg` | Kernel + module signing key not trusted | [recovery.md](recovery.md) |

## Why no Microsoft-signed shim

A Microsoft-signed shim would let end users on stock Debian and Ubuntu boot the hardened kernel without enrolling a MOK at all. We don't ship one.

Microsoft's UEFI signing requires the kernel + module signing key to live in an HSM with documented dual-factor authorization. This project's signing key lives in Forgejo's secret store so that CI can build and sign automatically; that automation is what meets the [48-hour CVE SLA](cve-policy.md). The two choices are incompatible.

If you want to argue for the other choice (acquire an HSM, accept slower CVE response, ship a Microsoft-signed shim), please file an issue.
