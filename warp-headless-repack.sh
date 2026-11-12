#!/usr/bin/env bash
# Repack the official cloudflare-warp .deb without the desktop GUI
# (warp-taskbar, Flutter runtime, WebKitGTK/AppIndicator dependencies).
# The resulting package keeps warp-svc, warp-cli, warp-diag and warp-dex.
#
# Usage:
#   ./warp-headless-repack.sh                         # latest version for this system's suite/arch
#   ./warp-headless-repack.sh cloudflare-warp_X.deb   # repack a local .deb
#   SUITE=jammy ARCH=arm64 ./warp-headless-repack.sh  # pick suite/arch explicitly
#   SUITE=noble ./warp-headless-repack.sh --version   # print the latest upstream version only
#
# Environment:
#   SUITE       distribution codename on pkg.cloudflareclient.com (default: from /etc/os-release,
#               preferring UBUNTU_CODENAME on Ubuntu derivatives)
#   ARCH        amd64 or arm64 (default: dpkg --print-architecture)
#   OUT_DIR     output directory (default: current directory)
#   SUFFIX      appended to the upstream version (default: +headless1)
#   MAINTAINER  if set, becomes the Maintainer field; the original one is kept as Original-Maintainer
#
# Requires dpkg-deb, curl, gpg and gpgv. Does not need root.
set -euo pipefail
umask 022

REPO=https://pkg.cloudflareclient.com
SUFFIX=${SUFFIX:-+headless1}

# Dependencies that only the GUI needs
GUI_DEPS='desktop-file-utils libayatana-appindicator3-1 libwebkit2gtk-4.1-0 libwebkit2gtk-4.0-37 libgtk-3-0 libgtk-3-0t64'

# Files that only the GUI uses (relative to the package root)
GUI_PATHS=(
  bin/warp-taskbar
  usr/bin/warp-taskbar
  usr/lib/warp
  usr/lib/systemd/user/warp-taskbar.service
  usr/share/applications
  usr/share/dbus-1/services/com.cloudflare.WarpTaskbar.service
  usr/share/icons
  etc/xdg/autostart
)

die() { echo "error: $*" >&2; exit 1; }
log() { echo ">> $*" >&2; }
for c in dpkg-deb curl gpg gpgv sha256sum md5sum; do command -v "$c" >/dev/null || die "missing $c"; done

OUT_DIR=$(mkdir -p "${OUT_DIR:-$PWD}" && cd "${OUT_DIR:-$PWD}" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fetch and verify the repository index; sets ver/file/sha
fetch_index() {
  # UBUNTU_CODENAME is set on Ubuntu derivatives (Linux Mint, Pop!_OS, ...)
  SUITE=${SUITE:-$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")}
  ARCH=${ARCH:-$(dpkg --print-architecture)}
  [[ -n $SUITE ]] || die "cannot detect the distribution codename; set SUITE (noble, jammy, bookworm, ...)"
  log "reading $REPO index for $SUITE/$ARCH"
  curl -fsSL "$REPO/pubkey.gpg" | gpg --dearmor > "$WORK/cf.gpg"
  curl -fsSL "$REPO/dists/$SUITE/InRelease" -o "$WORK/InRelease"
  gpgv --keyring "$WORK/cf.gpg" "$WORK/InRelease" 2>/dev/null || die "InRelease signature check failed"
  curl -fsSL "$REPO/dists/$SUITE/main/binary-$ARCH/Packages" -o "$WORK/Packages"
  local want
  want=$(awk -v f="main/binary-$ARCH/Packages" '/^SHA256:/{s=1;next} /^[A-Za-z]/{s=0} s && $3==f {print $1}' "$WORK/InRelease")
  [[ -n $want ]] || die "InRelease has no index for $ARCH"
  (cd "$WORK" && echo "$want  Packages" | sha256sum -c --quiet) || die "Packages checksum mismatch"
  # The index may list several versions; take the newest
  read -r ver file sha < <(awk '
      /^Version:/{v=$2} /^Filename:/{f=$2} /^SHA256:/{s=$2}
      /^$/{if(f)print v,f,s; v=f=s=""} END{if(f)print v,f,s}' "$WORK/Packages" |
    sort -V | tail -n1) || true
  [[ -n ${file:-} ]] || die "cloudflare-warp not found in the Packages index"
}

if [[ ${1:-} == --version ]]; then
  fetch_index
  echo "$ver"
  exit 0
fi

# ---------- 1. Get the original package ----------
if [[ $# -ge 1 ]]; then
  SRC_DEB=$(readlink -f "$1")
  [[ -f $SRC_DEB ]] || die "file not found: $1"
else
  fetch_index
  log "downloading version $ver"
  curl -fSL --progress-bar "$REPO/$file" -o "$WORK/orig.deb"
  (cd "$WORK" && echo "$sha  orig.deb" | sha256sum -c --quiet) || die "SHA256 mismatch for the downloaded .deb"
  SRC_DEB=$WORK/orig.deb
fi

# ---------- 2. Unpack ----------
PKG=$WORK/pkg
mkdir -p "$PKG/DEBIAN"
dpkg-deb -x "$SRC_DEB" "$PKG"
dpkg-deb -e "$SRC_DEB" "$PKG/DEBIAN"
[[ $(dpkg-deb -f "$SRC_DEB" Package) == cloudflare-warp ]] || die "not a cloudflare-warp package"

# ---------- 3. Remove GUI files ----------
for p in "${GUI_PATHS[@]}"; do rm -rf "${PKG:?}/$p"; done
# Drop directories left empty (usr/share/dbus-1, etc/xdg, ...)
find "$PKG" -mindepth 1 -type d -empty -delete
for b in warp-svc warp-cli; do
  [[ -x $PKG/bin/$b || -x $PKG/usr/bin/$b ]] || die "$b is missing after repacking; the upstream layout may have changed"
done
# No symlink may point at something that was removed
while IFS= read -r -d '' l; do
  t=$(readlink "$l")
  [[ $t == /* ]] && abs=$PKG$t || abs=$(dirname "$l")/$t
  [[ -e $abs ]] || die "dangling symlink: ${l#"$PKG"/} -> $t"
done < <(find "$PKG" -type l -print0)
# The remaining binaries must not depend on the removed /usr/lib/warp
if grep -rlaF /usr/lib/warp "$PKG"/bin "$PKG"/usr/bin 2>/dev/null | grep -q .; then
  die "a binary references /usr/lib/warp; the GUI directory cannot be removed safely"
fi

# ---------- 4. Strip the desktop parts of the maintainer scripts ----------
# Upstream postinst/prerm/postrm contain "Full-package-only" shell functions that
# start/stop warp-taskbar for every logged-in user via systemctl --user, run
# update-desktop-database and clean GUI data under ~/.local/share.
# They are removed function by function:
#  - leaf functions whose name or body mentions taskbar/desktop/flutter/gui/.local/share
#  - every line that calls one of them (including "for_each_regular_user <func>")
#  - helpers that are no longer called afterwards (for_each_regular_user)
STRIP_AWK='
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
# The same function name can be defined more than once (postinst embeds one copy
# in after_install and one in after_upgrade), so definitions are tracked by id.
NR == FNR {
  line = $0
  if (line ~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) {
    name = trim(line); sub(/[ \t]*\(\).*/, "", name)
    nf++; fnm[nf] = name; fs[nf] = FNR; defined[name] = 1
    if (sp > 0) nested[sid[sp]] = 1
    if (line ~ /\(\)[ \t]*\{[ \t]*$/) { sp++; sid[sp] = nf; sd[sp] = depth; depth++ }
    else pend = nf
    next
  }
  if (line ~ /^[ \t]*\{[ \t]*$/) {
    if (pend) { sp++; sid[sp] = pend; sd[sp] = depth; pend = 0 }
    depth++; next
  }
  if (line ~ /^[ \t]*\}[ \t;]*$/) {
    depth--
    if (sp > 0 && sd[sp] == depth) { fe[sid[sp]] = FNR; sp-- }
    next
  }
  if (sp > 0) body[sid[sp]] = body[sid[sp]] "\n" line
  n = split(trim(line), w, /[ \t]+/)
  nc++; cl[nc] = FNR; cw[nc] = w[1]; ca[nc] = (n > 1 ? w[2] : ""); cin[nc] = (sp > 0 ? fnm[sid[sp]] : "")
  next
}
FNR == 1 {
  if (depth != 0 || sp != 0 || pend) { print "brace mismatch" > "/dev/stderr"; exit 3 }
  gui = "taskbar|[Dd]esktop|flutter|[Gg][Uu][Ii]|\\.local/share"
  for (i = 1; i <= nf; i++) if (!nested[i] && (fnm[i] ~ gui || body[i] ~ gui)) R[fnm[i]] = 1
  do {
    changed = 0
    for (f in defined) {
      if (f in R) continue
      had = live = 0
      for (i = 1; i <= nc; i++) {
        if (cw[i] != f) continue
        had++
        if (!(cin[i] in R) && !(cw[i] in R) && !(ca[i] in R)) live++
      }
      if (had && !live) { R[f] = 1; changed = 1 }
    }
  } while (changed)
  for (i = 1; i <= nf; i++) if (fnm[i] in R) for (l = fs[i]; l <= fe[i]; l++) skip[l] = 1
  for (f in R) removed = removed " " f
  for (i = 1; i <= nc; i++) if ((cw[i] in R) || (ca[i] in R)) skip[cl[i]] = 1
  print "   removed functions:" removed > "/dev/stderr"
}
skip[FNR] { next }
/^[ \t]*#.*Full-package-only/ { next }
{ print }
'
for s in postinst prerm postrm preinst; do
  f=$PKG/DEBIAN/$s
  [[ -f $f ]] || continue
  log "patching $s"
  awk "$STRIP_AWK" "$f" "$f" > "$f.new" || die "failed to parse $s; the upstream script layout may have changed"
  cat "$f.new" > "$f" && rm -f "$f.new"   # overwrite in place to keep the executable bit
  sh -n "$f" || die "$s has a syntax error after patching"
  if left=$(grep -nE 'taskbar|[Dd]esktop|flutter|\.local/share|for_each_regular_user|systemctl --user' "$f" | grep -vE '^[0-9]+:[[:space:]]*#'); then
    die "$s still contains GUI-related code, please check manually:
$left"
  fi
done

# ---------- 5. Update the control file ----------
CTRL=$PKG/DEBIAN/control
deps=$(sed -n 's/^Depends: //p' "$CTRL")
newdeps=$(tr ',' '\n' <<<"$deps" | sed 's/^ *//; s/ *$//' | while read -r d; do
  name=${d%% *}
  [[ " $GUI_DEPS " == *" $name "* ]] || echo "$d"
done | paste -sd, - | sed 's/,/, /g')
oldver=$(sed -n 's/^Version: //p' "$CTRL")
size=$(du -sk --exclude=DEBIAN "$PKG" | cut -f1)
awk -v deps="$newdeps" -v ver="$oldver$SUFFIX" -v size="$size" -v maint="${MAINTAINER:-}" '
  /^Description:/ { indesc = 1; next }
  indesc && /^[ \t]/ { next }
  { indesc = 0 }
  /^Depends:/ { print "Depends: " deps; next }
  /^Version:/ { print "Version: " ver; next }
  /^Installed-Size:/ { print "Installed-Size: " size; next }
  /^Maintainer:/ && maint != "" { print "Maintainer: " maint; print "Original-" $0; next }
  { print }
  END {
    print "Description: Cloudflare WARP client (unofficial headless repack)"
    print " Repackaged from the official cloudflare-warp package with the desktop GUI"
    print " (warp-taskbar and its Flutter runtime) and the GUI-only dependencies removed."
    print " Contains warp-svc, warp-cli, warp-diag and warp-dex."
    print " This is not an official Cloudflare package."
  }
' "$CTRL" > "$CTRL.new" && mv "$CTRL.new" "$CTRL"

# ---------- 6. Regenerate md5sums ----------
( cd "$PKG" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z | xargs -0 md5sum ) > "$PKG/DEBIAN/md5sums"

# ---------- 7. Build ----------
arch=$(sed -n 's/^Architecture: //p' "$CTRL")
OUT=$OUT_DIR/cloudflare-warp_${oldver}${SUFFIX}_${arch}.deb
dpkg-deb --root-owner-group -Zxz -b "$PKG" "$OUT" >/dev/null

echo
echo ">> done: $OUT"
echo "   size: $(du -h "$SRC_DEB" | cut -f1) -> $(du -h "$OUT" | cut -f1)"
echo "   removed dependencies: $(comm -23 <(tr ',' '\n' <<<"$deps" | awk '{print $1}' | sort) <(tr ',' '\n' <<<"$newdeps" | awk '{print $1}' | sort) | paste -sd' ')"
echo "   Depends: $newdeps"
echo
echo "install with: sudo apt install $OUT"
