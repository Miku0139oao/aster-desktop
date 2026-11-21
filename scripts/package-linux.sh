#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$(cd "$1" && pwd)"
cd "$root"
version="$(sed -n 's/^version: \([^+ ]*\)+[0-9][0-9]*$/\1/p' pubspec.yaml | head -1)"
if [ -z "$version" ]; then echo 'Could not read version from pubspec.yaml' >&2; exit 1; fi
. /etc/os-release
case "$ID" in
  ubuntu) target=ubuntu-24.04;;
  arch) target=arch;;
  *) echo 'Package on Ubuntu 24.04 or Arch Linux to match native dependencies' >&2; exit 1;;
esac
if [ "$ID" = ubuntu ] && [ "$VERSION_ID" != 24.04 ]; then
  echo 'Build the Ubuntu package on Ubuntu 24.04' >&2; exit 1
fi
# DrvFs can report Windows files as 0777. Never preserve group/world write
# permissions in packages that may become privileged service executables.
tar --mode='u+rwX,go+rX,go-w' -C "$bundle" -czf "dist/Aster-Desktop-$version-linux-$target-x64-portable.tar.gz" .
stage="$root/.build/linux-package"
mkdir -p "$stage/usr/lib/aster-desktop" "$stage/usr/bin" "$stage/usr/share/applications" "$stage/usr/share/icons/hicolor/512x512/apps"
cp -a "$bundle/." "$stage/usr/lib/aster-desktop/"
cp assets/aster.png "$stage/usr/share/icons/hicolor/512x512/apps/aster-desktop.png"
cp packaging/linux/aster-desktop.desktop "$stage/usr/share/applications/"
printf '#!/bin/sh\nexec /usr/lib/aster-desktop/aster_desktop "$@"\n' > "$stage/usr/bin/aster-desktop"
chmod 755 "$stage/usr/bin/aster-desktop"
if [ "$ID" = ubuntu ]; then
mkdir -p "$stage/DEBIAN"
cp packaging/linux/control "$stage/DEBIAN/control"
if ! grep -q '#ASTER_VERSION' "$stage/DEBIAN/control"; then
  echo 'packaging/linux/control lost its version placeholder' >&2; exit 1
fi
sed -i "s/#ASTER_VERSION/$version/" "$stage/DEBIAN/control"
cp packaging/linux/prerm "$stage/DEBIAN/prerm"
chmod 755 "$stage/DEBIAN/prerm"
if command -v dpkg-deb >/dev/null; then
  deb="dist/Aster-Desktop-$version-linux-x64.deb"
  dpkg-deb --build --root-owner-group "$stage" "$deb"
  if [ "$(dpkg-deb -f "$deb" Version)" != "$version" ]; then
    echo "The .deb was packaged with a foreign version" >&2; exit 1
  fi
else
  debstage="$root/.build/deb-package"
  mkdir -p "$debstage"
  printf '2.0\n' > "$debstage/debian-binary"
  tar -C "$stage/DEBIAN" --owner=0 --group=0 -czf "$debstage/control.tar.gz" .
  tar --mode='u+rwX,go+rX,go-w' -C "$stage" --owner=0 --group=0 -czf "$debstage/data.tar.gz" usr
  (cd "$debstage" && ar rcD "$root/dist/Aster-Desktop-$version-linux-x64.deb" debian-binary control.tar.gz data.tar.gz)
fi
fi
if [ "$ID" = arch ]; then
archstage="$root/.build/arch-package"
mkdir -p "$archstage"
cp -a "$stage/usr" "$archstage/"
cat > "$archstage/.PKGINFO" <<EOF
pkgname = aster-desktop
pkgbase = aster-desktop
pkgver = $version-1
pkgdesc = Material 3 desktop client powered by Aster Core
url = https://github.com/Miku0139oao/aster-desktop
arch = x86_64
license = GPL3
depend = gtk3
depend = libappindicator
depend = polkit
depend = systemd
depend = ca-certificates
optdepend = kconfig: KDE proxy settings
optdepend = gsettings-desktop-schemas: GNOME proxy settings
EOF
cp packaging/linux/aster-desktop.install "$archstage/.INSTALL"
tar --mode='u+rwX,go+rX,go-w' -C "$archstage" --owner=0 --group=0 --zstd -cf dist/Aster-Desktop-$version-linux-x64.pkg.tar.zst .
fi
