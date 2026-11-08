# warp-headless

English | [简体中文](README.zh-CN.md)

Unofficial headless builds of the Cloudflare WARP client for Debian and Ubuntu.

The official `cloudflare-warp` package ships the desktop tray app (`warp-taskbar`, built with Flutter) together with the daemon and the command-line tools, and depends on WebKitGTK and AppIndicator. On a minimal Ubuntu 24.04 system, installing it pulls in about 200 additional packages (GTK, WebKit, GStreamer, ...). This repository repackages the official `.deb` without the GUI. The same package installs about 10.

**Kept:** `warp-svc`, `warp-cli`, `warp-diag`, `warp-dex`, `warp-svc.service`, and the parts of the maintainer scripts that set capabilities, enable the service, and clean up on removal.

**Removed:** `warp-taskbar`, `/usr/lib/warp` (Flutter runtime and plugins), `.desktop` files, the D-Bus service, the systemd user unit, the maintainer-script code that manages the tray app for each desktop user, and the dependencies `libwebkit2gtk-4.1-0`, `libayatana-appindicator3-1` and `desktop-file-utils`.

The binaries themselves are not modified.

## Packages

GitHub Actions builds packages for these distributions:

| Distribution | Codename | Architectures |
|---|---|---|
| Ubuntu 22.04 | jammy | amd64, arm64 |
| Ubuntu 24.04 | noble | amd64, arm64 |
| Debian 12 | bookworm | amd64, arm64 |
| Debian 13 | trixie | amd64, arm64 |

Release assets are named `cloudflare-warp_<version>-headless1_<codename>_<arch>.deb`. Each release includes a `SHA256SUMS` file.

## Install

Download the package for your distribution from the [latest release](https://github.com/ninjin1020/warp-headless/releases/latest), or use the GitHub API:

```bash
SUITE=noble ARCH=amd64
url=$(curl -fsSL https://api.github.com/repos/ninjin1020/warp-headless/releases/latest \
  | grep -o "https://[^\"]*_${SUITE}_${ARCH}\.deb" | head -n1)
curl -fLO "$url"
curl -fsSL https://github.com/ninjin1020/warp-headless/releases/latest/download/SHA256SUMS | sha256sum -c --ignore-missing
sudo apt install "./${url##*/}"
```

`warp-cli` and `warp-svc` work exactly as in the official package. See the [Cloudflare WARP client documentation](https://developers.cloudflare.com/warp-client/) for usage.

### Notes

- The package is still named `cloudflare-warp`, with `+headless1` appended to the version. If Cloudflare's APT repository is configured on the same machine, `apt upgrade` will replace it with the full package once a newer upstream version is published. Either don't add that repository, or pin the package with `sudo apt-mark hold cloudflare-warp`.
- To upgrade, install the package from a newer release.
- During installation the upstream maintainer script may print a notice about the APT repository key. It is harmless.

## How it works

[`warp-headless-repack.sh`](warp-headless-repack.sh):

1. Downloads `InRelease` from `pkg.cloudflareclient.com`, verifies its signature with Cloudflare's published key, then checks the `Packages` index and the `.deb` against the signed SHA256 sums.
2. Unpacks the package, deletes the GUI files, and checks that no remaining binary or symlink refers to them.
3. Removes the desktop-only functions from `postinst`, `prerm` and `postrm` and the lines that call them, then checks the scripts' syntax and fails if any GUI-related code is left.
4. Drops the GUI-only dependencies, updates the version, `Installed-Size`, `Maintainer` and description, regenerates `md5sums`, and rebuilds the package.

The script stops with an error rather than producing a package when the upstream layout changes in an unexpected way.

## Automated builds

[`.github/workflows/build.yml`](.github/workflows/build.yml):

- Checks Cloudflare's repository once a day. When there is a new version, it builds every distribution and architecture and publishes a release tagged `v<upstream version>`.
- Also runs on pushes to `main` that change the build files, and on manual dispatch (`force` rebuilds the current version).
- Installs each package in a clean container of the matching distribution (arm64 under QEMU). The check fails if any GUI package is pulled in, a shared library is missing, `warp-cli` does not run, or `warp-svc` capabilities are not set. See [`ci/smoke-test.sh`](ci/smoke-test.sh).

To change the distributions or architectures, edit `SUITES` and `ARCHES` at the top of the workflow.

## Build locally

Run this on a Debian-based system with `dpkg-deb`, `curl`, `gpg` and `gpgv`. Root is not required.

```bash
./warp-headless-repack.sh                          # latest version for the current system
SUITE=jammy ARCH=arm64 ./warp-headless-repack.sh   # a specific distribution and architecture
./warp-headless-repack.sh cloudflare-warp_X.deb    # an existing .deb
```

Environment variables: `SUITE`, `ARCH`, `OUT_DIR`, `SUFFIX` (default `+headless1`), `MAINTAINER`.

## Disclaimer

This project is not affiliated with, endorsed by, or supported by Cloudflare, Inc. "Cloudflare" and "WARP" are trademarks of Cloudflare, Inc.

The WARP client is proprietary software distributed by Cloudflare under its own terms. See the [Cloudflare Application Terms of Service](https://www.cloudflare.com/application/terms/). The release assets contain Cloudflare's unmodified binaries, repackaged. The MIT license of this repository covers only the scripts and workflow files in it, not Cloudflare's software.

Use at your own risk. For issues with the packaging, open an issue here. Don't contact Cloudflare support about these packages.

## License

[MIT](LICENSE)
