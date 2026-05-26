# Pinning the hardened kernel as preferred

The hardened kernel's package name (`linux-image-X.Y.Z-hardened-unredacted-amd64`) differs from the distro stock kernel, so the two coexist by default. If you also installed the stock `linux-image-amd64` meta-package as a recovery fallback, pinning ensures `apt upgrade` doesn't prefer the stock kernel's newer versions over ours when both are available.

## Pin the hardened kernel above the distro kernel

First, find the exact `Origin:` string Forgejo emits in our `Release` file. After enabling the repo source (see [install.md](install.md)):

```
apt-cache policy linux-image-hardened-unredacted-amd64 | sed -n 's/.*o=\([^,]*\).*/\1/p' | head -n1
```

This prints the `Origin:` value (likely `unredacted`, possibly different depending on Forgejo's registry behavior). Use it in the pin file. Narrow `Package:` to hardened-kernel packages only so the pin doesn't accidentally re-rank any distro kernels that share the `linux-image-*` name:

```
sudo tee /etc/apt/preferences.d/unredacted-hardened.pref >/dev/null <<EOF
Package: linux-image-*-hardened-unredacted-* linux-headers-*-hardened-unredacted-*
Pin: release o=<ORIGIN_FROM_ABOVE>
Pin-Priority: 990
EOF
```

Priority 990 is above the apt default (500). Verify:

```
apt-cache policy linux-image-hardened-unredacted-amd64
```

The hardened source line should appear with priority `990`, above any stock-distro source.

## Lower priority: only prefer when no newer stock update exists

```
Pin-Priority: 600
```

## Pin to a specific hardened version

```
sudo apt-mark hold linux-image-6.12.8-hardened-unredacted-amd64
```

`apt-mark unhold` reverses it.
