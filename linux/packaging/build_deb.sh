#!/bin/sh
# Builds a .deb (Debian, Ubuntu, Mint...) from a Linux release bundle:
#
#   flutter build linux --release
#   sh linux/packaging/build_deb.sh build/linux/x64/release/bundle x64 dist/Zen-Linux-x64.deb
#
# Only dpkg-deb is needed (dpkg-shlibdeps from dpkg-dev, when present, works
# out the library dependencies; otherwise a fixed list is used). The app goes
# to /opt/zen, a zen command to /usr/bin, the .desktop file (menu, zen://
# links and Zen's own files, the Wayland icon), the types of those files, the
# icon and the AppStream metadata to /usr/share (dpkg's triggers refresh the
# menu and the file types).
# The release workflow (.github/workflows/release.yml) runs this.
set -eu
export LC_ALL=C

if [ "$#" -ne 3 ]; then
  echo "usage: build_deb.sh <bundle dir> <x64|arm64> <output .deb>" >&2
  exit 2
fi
bundle=$(cd "$1" && pwd)
arch=$2
out=$3
here=$(cd "$(dirname "$0")" && pwd)
project=$(cd "$here/../.." && pwd)

case "$arch" in
  x64) deb_arch=amd64 ;;
  arm64) deb_arch=arm64 ;;
  *)
    echo "error: build_deb.sh: unknown architecture: $arch" >&2
    exit 2
    ;;
esac
if [ ! -x "$bundle/zen" ] || [ ! -f "$bundle/lib/libyggdrasil_bridge.so" ]; then
  echo "error: $bundle is not a Zen release bundle (zen, lib/libyggdrasil_bridge.so)" >&2
  exit 1
fi

version=$(sed -n 's/^version: *\([0-9][0-9.]*\).*$/\1/p' "$project/pubspec.yaml")
if [ -z "$version" ]; then
  echo "error: no version in pubspec.yaml" >&2
  exit 1
fi
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
  date=$(date -u -d "@$SOURCE_DATE_EPOCH" +%Y-%m-%d)
else
  date=$(date -u +%Y-%m-%d)
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zen-deb.XXXXXX")
trap 'rm -rf "$work"' EXIT
root="$work/root"
share="$root/usr/share"
mkdir -p "$root/DEBIAN" "$root/opt/zen" "$root/usr/bin" \
  "$share/applications" "$share/metainfo" "$share/doc/zen" "$share/mime/packages" \
  "$share/icons/hicolor/256x256/apps"

cp -R "$bundle/." "$root/opt/zen/"
# The tar.gz helper has nothing to do in a package.
rm -f "$root/opt/zen/install-desktop-entry.sh"
chmod -R u+rwX,go+rX,go-w "$root/opt/zen"
ln -s /opt/zen/zen "$root/usr/bin/zen"

sed 's|^Exec=.*|Exec=/opt/zen/zen %u|' "$here/com.roj.zen.desktop" \
  > "$share/applications/com.roj.zen.desktop"
sed "s|<release version=\"[^\"]*\" date=\"[^\"]*\"/>|<release version=\"$version\" date=\"$date\"/>|" \
  "$here/com.roj.zen.metainfo.xml" > "$share/metainfo/com.roj.zen.metainfo.xml"
cp "$bundle/data/app_icon.png" "$share/icons/hicolor/256x256/apps/com.roj.zen.png"
cp "$bundle/data/com.roj.zen.mime.xml" "$share/mime/packages/com.roj.zen.xml"
cat "$project/NOTICE" "$project/LICENSE" > "$share/doc/zen/copyright"
find "$share" -type f -exec chmod 0644 {} +

# Libraries from the system (GTK, libsecret, GStreamer, the app indicator):
# dpkg-shlibdeps reads them from the binaries; the bundle's own libraries in
# /opt/zen/lib are private.
depends=""
if command -v dpkg-shlibdeps > /dev/null 2>&1; then
  mkdir -p "$work/debian"
  printf 'Source: zen\n\nPackage: zen\nArchitecture: any\n' > "$work/debian/control"
  set -- -e"$root/opt/zen/zen"
  for library in "$root"/opt/zen/lib/*.so*; do
    if [ -f "$library" ] && [ ! -L "$library" ]; then
      set -- "$@" -e"$library"
    fi
  done
  if shlibs=$(cd "$work" && dpkg-shlibdeps -O --ignore-missing-info \
    -l"$root/opt/zen/lib" "$@" 2> "$work/shlibdeps.log"); then
    # The release is built on Ubuntu 22.04 (names without t64; Debian 13
    # and Ubuntu 24.04+ renamed some libraries ...t64 and their packages
    # provide the old names, which CI's deb-install job checks). Built on
    # a t64 system, older Debian and Ubuntu get the plain name as well.
    depends=$(printf '%s\n' "$shlibs" | sed -n 's/^shlibs:Depends=//p' |
      sed -E 's/([a-z0-9.+-]+)t64( \([^)]*\))?/\1t64\2 | \1\2/g')
  else
    echo "warning: dpkg-shlibdeps failed, using the fixed dependency list:" >&2
    cat "$work/shlibdeps.log" >&2
  fi
fi
if [ -z "$depends" ]; then
  depends="libgtk-3-0t64 | libgtk-3-0, libsecret-1-0, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, libayatana-appindicator3-1"
fi

size=$(du -sk "$root/opt" "$root/usr" | awk '{ total += $1 } END { print total }')
cat > "$root/DEBIAN/control" << EOF
Package: zen
Version: $version
Architecture: $deb_arch
Maintainer: Robert Ostrowski-Jagoda
Installed-Size: $size
Depends: $depends
Recommends: gstreamer1.0-plugins-good, gstreamer1.0-libav, gnome-keyring | kwalletmanager, libayatana-appindicator3-1, libpulse0
Section: net
Priority: optional
Homepage: https://github.com/robertostrowskijagoda/Zen
Description: network of people who know each other
 Zen connects you with people you know, directly and without servers, ads
 or an algorithm: messages, calls and posts travel between your friends'
 devices over an encrypted mesh network (Yggdrasil).
 .
 The encryption key is kept in the system keyring (GNOME Keyring or
 KWallet); voice messages and films play through GStreamer.
EOF

mkdir -p "$(dirname "$out")"
dpkg-deb --root-owner-group -Zxz --build "$root" "$out"
