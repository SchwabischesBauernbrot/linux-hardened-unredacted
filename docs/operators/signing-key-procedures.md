# Signing-key procedures

The kernel + module signing key lives in Forgejo's secret store as two values:

- `KERNEL_SIGNING_KEY`: PEM-encoded private key.
- `KERNEL_SIGNING_CERT`: matching X.509 certificate, PEM-encoded.

The certificate is what end users enroll via MOK. Its DER form is what would be embedded in a future shim build if the project ever acquires HSM-backed signing; that track is currently blocked.

## Generation

Run on a clean, network-isolated workstation. The private key must never touch a network-connected machine outside Forgejo's secret store.

```
openssl req -new -nodes -utf8 -sha256 -days 1825 \
    -batch -x509 -subj "/CN=unredacted linux-hardened signing/" \
    -newkey rsa:3072 \
    -keyout signing.key \
    -outform PEM -out signing.crt
```

RSA-3072 is adequate for code-signing through 2030+; EC P-384 works equally well, pick one. The 1825-day (5-year) validity is a fallback for missed-rotation scenarios; the policy rotation cadence is 12 months. The Subject CN is what users see in MOK enrollment screens.

Verify the key + cert pair:

```
openssl x509 -in signing.crt -noout -fingerprint -sha256
openssl rsa  -in signing.key -noout -modulus | openssl sha256
openssl x509 -in signing.crt -noout -modulus | openssl sha256
# the last two SHA-256s must match
```

## Loading into Forgejo

In the Forgejo repo settings → Actions → Secrets:

- Add secret `KERNEL_SIGNING_KEY` with the contents of `signing.key`.
- Add secret `KERNEL_SIGNING_CERT` with the contents of `signing.crt`.

Restrict to the `build-kernel` workflow only. Do not expose to `publish` or any other workflow.

After loading, securely delete the workstation copies of `signing.key`:

```
shred -u -n 7 signing.key
# or, on macOS: rm -P signing.key
```

Keep `signing.crt`; it's public and gets published with each release.

## Backup

The private key cannot be reconstructed from the cert. Loss of the key without backup means all future updates require a new key, rotated through MOK on every end user's machine. The project survives that, but the rotation is disruptive.

Keep a single offline encrypted backup:

```
gpg --symmetric --cipher-algo AES256 --output signing.key.gpg signing.key
# move signing.key.gpg to an offline encrypted volume; record the
# passphrase in a separate physical password manager
```

Do not back up to any networked location. The backup's purpose is recovery after losing the Forgejo secret, which presumably correlates with losing Forgejo.

## Rotation

Annual, or on suspected compromise.

1. Generate a new key + cert pair per "Generation" above.
2. Publish a release-notes entry 60+ days ahead with the new cert fingerprint.
3. Update the Forgejo secrets to the new values on the rotation date.
4. The next build signs with the new key.
5. End users see a new MOK enrollment prompt on their next kernel update. They follow the existing [secure-boot.md](../users/secure-boot.md) flow.

After rotation, keep the old cert published in release notes for at least one rotation cycle so users verifying older builds can still chain trust. Securely destroy the offline backup of the old private key once the old kernels are no longer in `main`.

## Revocation (suspected compromise)

If the Forgejo host is compromised, treat the key as compromised. Forgejo's secret store is not designed to resist an attacker with admin access.

1. Immediately revoke the cert via release notes and the project's out-of-band channels (website, social).
2. Generate a new key + cert pair on a clean workstation.
3. Update Forgejo secrets.
4. Publish an emergency point release of the kernel signed by the new key.
5. Communicate to end users: `mokutil --delete` the old cert, then install the new kernel, which prompts MOK enrollment of the new cert.

There is no certificate revocation list mechanism on the kernel side; kernel signature verification compares against enrolled certs, not against a CRL. Revocation is therefore two operational steps: stop enrolling the old cert, and rotate every user forward to the new one.

## Destruction (project sunset)

If the project shuts down:

1. Stop publishing new builds.
2. After the existing `main` versions are no longer recommended for production, destroy the Forgejo secrets and the offline backup.
3. End users running the kernel continue to boot until their cert ages out (5 years on the default issuance). They'll need to migrate to another kernel before then.
