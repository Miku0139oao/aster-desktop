#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
flutter="${ASTER_FLUTTER:-flutter}"
"$flutter" --version --machine | python3 -c 'import json,sys; assert json.load(sys.stdin)["frameworkVersion"] == "3.47.6", "Use Flutter 3.47.6"'
mkdir -p .build dist
export CGO_ENABLED=0
export GOTOOLCHAIN=go1.26.3
case "$(uname -s)" in Darwin) platform=darwin;; Linux) platform=linux;; *) echo 'Use build.ps1 on Windows' >&2; exit 1;; esac
case "$(uname -m)" in x86_64) arch=amd64;; arm64|aarch64) arch=arm64;; *) exit 1;; esac
module=github.com/Miku0139oao/aster-core
version=v0.0.0-20260907022528-a9a33503b39a
source="$(cd bridge && go mod download -json "$module@$version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')"
assetarch="$arch"; if [ "$arch" = amd64 ]; then assetarch=amd64-v1; fi
(cd "$source" && go build -mod=readonly -tags with_gvisor -trimpath -ldflags "-s -w -X $module/constant.Version=alpha-main-a9a3350 -X $module/constant.ReleaseAsset=aster-core-$platform-$assetarch" -o "$root/.build/aster-core" .)
(cd bridge && go build -trimpath -o "$root/.build/aster-bridge" ./cmd/aster-bridge)
go run ./scripts/notices.go -core "$source" -out .build/third-party
"$flutter" pub get --enforce-lockfile
if [ "$platform" = linux ]; then
  "$flutter" build linux --release
  bundle=build/linux/x64/release/bundle
  cp .build/aster-{core,bridge} LICENSE NOTICE.md README.md toolchain.json "$bundle/"
  cp -a .build/third-party "$bundle/"
  cp -a docs "$bundle/"
  cp assets/OFL-NotoSansTC.txt "$bundle/"
  bash scripts/package-linux.sh "$bundle"
else
  "$flutter" build macos --release
  app='build/macos/Build/Products/Release/Aster Desktop.app'
  cp .build/aster-{core,bridge} LICENSE NOTICE.md README.md toolchain.json "$app/Contents/Resources/"
  cp -a .build/third-party "$app/Contents/Resources/"
  cp -a docs "$app/Contents/Resources/"
  cp assets/OFL-NotoSansTC.txt "$app/Contents/Resources/"
  mkdir -p "$app/Contents/Library/HelperTools" "$app/Contents/Library/LaunchDaemons"
  swiftc -O -target "$(uname -m)-apple-macos13.0" -framework Foundation -framework Security macos/Helper/main.swift -o "$app/Contents/Library/HelperTools/aster-helper"
  cp macos/Helper/app.astercore.desktop.helper.plist "$app/Contents/Library/LaunchDaemons/"
  identity="${ASTER_SIGN_IDENTITY:--}"
  codesign --force --deep --sign "$identity" "$app"
  staging="$root/.build/pkgroot"
  mkdir -p "$staging/Applications"
  ditto "$app" "$staging/Applications/Aster Desktop.app"
  pkgbuild --root "$staging" --identifier app.astercore.desktop --version 0.1.2 --ownership recommended .build/Aster-Desktop.pkg
  diskstage="$root/.build/dmg-$arch"
  mkdir -p "$diskstage"
  cp .build/Aster-Desktop.pkg "$diskstage/Install Aster Desktop.pkg"
  cp README.md "$diskstage/Readme.md"
  # Leave filesystem space for the large installer rather than relying on the
  # default estimate, which can be too small for compressed Go/Flutter bundles.
  disksize=$(( $(du -sk "$diskstage" | awk '{print $1}') / 1024 + 64 ))
  hdiutil create -volname 'Aster Desktop' -srcfolder "$diskstage" -size "${disksize}m" -fs HFS+ -ov -format UDZO "dist/Aster-Desktop-0.1.2-macos-$arch.dmg"
  if [ -n "${ASTER_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "dist/Aster-Desktop-0.1.2-macos-$arch.dmg" --keychain-profile "$ASTER_NOTARY_PROFILE" --wait
    xcrun stapler staple "dist/Aster-Desktop-0.1.2-macos-$arch.dmg"
  fi
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then bash scripts/package-source.sh "$source"; fi
python3 -c 'import pathlib,hashlib; d=pathlib.Path("dist"); (d/"checksums.txt").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+p.name+"\n" for p in sorted(d.iterdir()) if p.is_file() and p.name != "checksums.txt"))'
