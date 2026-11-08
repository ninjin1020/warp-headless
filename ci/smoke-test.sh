#!/usr/bin/env bash
# Install a repacked .deb in a clean Debian/Ubuntu container and check that
# dependencies resolve, the binaries run and no GUI packages are pulled in.
# Usage: docker run -v "$PWD/out:/out:ro" -v "$PWD/ci:/ci:ro" ubuntu:noble bash /ci/smoke-test.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

fail() { echo "error: $*" >&2; exit 1; }

deb=$(ls /out/*.deb)
. /etc/os-release
echo ">> system: $PRETTY_NAME $(dpkg --print-architecture), package: $(basename "$deb")"

apt-get update -qq
before=$(dpkg-query -W -f '${Package}\n' | wc -l)
apt-get install -y -qq "$deb" >/tmp/apt.log 2>&1 || { cat /tmp/apt.log; fail "apt-get install failed"; }
after=$(dpkg-query -W -f '${Package}\n' | wc -l)
echo ">> newly installed packages (including cloudflare-warp): $((after - before))"

if dpkg-query -W -f '${Package}\n' | grep -iE 'webkit|gtk|gstreamer|ayatana|flutter'; then
  fail "GUI-related packages were installed"
fi

for b in warp-svc warp-cli warp-diag warp-dex; do
  if ldd "/bin/$b" | grep 'not found'; then
    fail "$b has unresolved shared libraries"
  fi
done

warp-cli --version
getcap /bin/warp-svc | grep -q cap_net_admin || fail "postinst did not set capabilities on warp-svc"
[[ ! -e /usr/lib/warp ]] || fail "/usr/lib/warp is still present"
echo ">> passed"
