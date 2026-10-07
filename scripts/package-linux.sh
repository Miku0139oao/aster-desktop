#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bundle="$(cd "$1" && pwd)"
cd "$root"
. /etc/os-release
case "$ID" in
  ubuntu) target=ubuntu-24.04;;
  arch) target=arch;;
  *) echo 'Package on Ubuntu 24.04 or Arch Linux to match native dependencies' >&2; exit 1;;
esac
if [ "$ID" = ubuntu ] && [ "$VERSION_ID" != 24.04 ]; then
  echo 'Build the Ubuntu package on Ubuntu 24.04' >&2; exit 1
fi
tar -C "$bundle" -czf "dist/Aster-Desktop-0.1.7-linux-$target-x64-portable.tar.gz" .
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
cp packaging/linux/prerm "$stage/DEBIAN/prerm"
chmod 755 "$stage/DEBIAN/prerm"
if command -v dpkg-deb >/dev/null; then
  dpkg-deb --build --root-owner-group "$stage" dist/Aster-Desktop-0.1.7-linux-x64.deb
else
  debstage="$root/.build/deb-package"
  mkdir -p "$debstage"
  printf '2.0\n' > "$debstage/debian-binary"
  tar -C "$stage/DEBIAN" --owner=0 --group=0 -czf "$debstage/control.tar.gz" .
  tar -C "$stage" --owner=0 --group=0 -czf "$debstage/data.tar.gz" usr
  (cd "$debstage" && ar rcD "$root/dist/Aster-Desktop-0.1.7-linux-x64.deb" debian-binary control.tar.gz data.tar.gz)
fi
fi
if [ "$ID" = arch ]; then
archstage="$root/.build/arch-package"
mkdir -p "$archstage"
cp -a "$stage/usr" "$archstage/"
cat > "$archstage/.PKGINFO" <<'EOF'
pkgname = aster-desktop
pkgbase = aster-desktop
pkgver = 0.1.7-1
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
tar -C "$archstage" --owner=0 --group=0 --zstd -cf dist/Aster-Desktop-0.1.7-linux-x64.pkg.tar.zst .
fi
