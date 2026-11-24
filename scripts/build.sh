#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
release_version="$(sed -n 's/^version: \([^+ ]*\)+[0-9][0-9]*$/\1/p' pubspec.yaml | head -1)"
if [ -z "$release_version" ]; then echo 'Could not read version from pubspec.yaml' >&2; exit 1; fi
mkdir -p .build/native dist
export CGO_ENABLED=0
engine_go="go$(python3 -c 'import json; print(json.load(open("toolchain.json"))["go"])')"
native_go="go$(python3 -c 'import json; print(json.load(open("toolchain.json"))["nativeGo"])')"
export GOTOOLCHAIN="$engine_go"
case "$(uname -s)" in Darwin) platform=darwin;; Linux) platform=linux;; *) echo 'Use build.ps1 on Windows' >&2; exit 1;; esac
case "$(uname -m)" in x86_64) arch=amd64;; arm64|aarch64) arch=arm64;; *) exit 1;; esac
module=github.com/Miku0139oao/aster-core
version=v0.0.0-20260907022528-a9a33503b39a
source="$(cd bridge && go mod download -json "$module@$version" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Dir"])')"
assetarch="$arch"; if [ "$arch" = amd64 ]; then assetarch=amd64-v1; fi
(cd "$source" && go build -mod=readonly -tags with_gvisor -trimpath -ldflags "-s -w -X $module/constant.Version=alpha-main-a9a3350 -X $module/constant.ReleaseAsset=aster-core-$platform-$assetarch" -o "$root/.build/aster-core" .)
(cd bridge && go build -trimpath -ldflags "-X github.com/Miku0139oao/aster-desktop/bridge/internal/desktop.Version=$release_version" -o "$root/.build/aster-bridge" ./cmd/aster-bridge)
export GOTOOLCHAIN="$native_go"
go run ./scripts/notices.go -core "$source" -engine-go "$engine_go" -out .build/third-party
populate_bundle() {
  cp .build/aster-{core,bridge} LICENSE NOTICE.md README.md toolchain.json "$1/"
  cp -a .build/third-party docs "$1/"
  cp assets/OFL-NotoSansTC.txt "$1/"
  cp assets/opencc/LICENSE "$1/LICENSE-OpenCC"
}
if [ "$platform" = linux ]; then
  bundle=.build/native/linux-bundle
  mkdir -p "$bundle"
  go build -mod=readonly -trimpath -ldflags '-s -w' -o "$bundle/aster_desktop" ./cmd/aster-desktop
  populate_bundle "$bundle"
  bash scripts/package-linux.sh "$bundle"
else
  app='.build/native/Aster Desktop.app'
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks" "$app/Contents/Library/HelperTools" "$app/Contents/Library/LaunchDaemons"
  go build -mod=readonly -trimpath -ldflags '-s -w' -o "$app/Contents/MacOS/Aster Desktop" ./cmd/aster-desktop
  populate_bundle "$app/Contents/Resources"
  build_number="$(sed -n 's/^version: [^+ ]*+\([0-9][0-9]*\)$/\1/p' pubspec.yaml | head -1)"
  sed -e "s/@VERSION@/$release_version/g" -e "s/@BUILD@/$build_number/g" macos/NativeInfo.plist > "$app/Contents/Info.plist"
  iconset=.build/native/Aster.iconset
  mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    icons=macos/Runner/Assets.xcassets/AppIcon.appiconset
    cp "$icons/app_icon_${size}.png" "$iconset/icon_${size}x${size}.png"
    cp "$icons/app_icon_$((size * 2)).png" "$iconset/icon_${size}x${size}@2x.png"
  done
  iconutil --convert icns --output "$app/Contents/Resources/Aster.icns" "$iconset"
  swift_target="$(uname -m)-apple-macos13.0"
  swiftc -O -target "$swift_target" -framework Foundation -framework Security macos/Helper/main.swift -o "$app/Contents/Library/HelperTools/aster-helper"
  swiftc -O -swift-version 5 -emit-library -target "$swift_target" -framework AppKit -framework Foundation -framework ServiceManagement macos/NativePrivilege.swift -o "$app/Contents/Frameworks/libAsterPrivilege.dylib"
  cp macos/Helper/app.astercore.desktop.helper.plist "$app/Contents/Library/LaunchDaemons/"
  identity="${ASTER_SIGN_IDENTITY:--}"
  codesign --force --deep --sign "$identity" "$app"
  staging="$root/.build/native/pkgroot"
  mkdir -p "$staging/Applications"
  ditto "$app" "$staging/Applications/Aster Desktop.app"
  pkgbuild --root "$staging" --identifier app.astercore.desktop --version "$release_version" --ownership recommended .build/Aster-Desktop.pkg
  diskstage="$root/.build/dmg-$arch"
  mkdir -p "$diskstage"
  cp .build/Aster-Desktop.pkg "$diskstage/Install Aster Desktop.pkg"
  cp README.md "$diskstage/Readme.md"
  # Leave filesystem space for the installer rather than relying on the
  # default estimate for a compressed bundle.
  disksize=$(( $(du -sk "$diskstage" | awk '{print $1}') / 1024 + 64 ))
  hdiutil create -volname 'Aster Desktop' -srcfolder "$diskstage" -size "${disksize}m" -fs HFS+ -ov -format UDZO "dist/Aster-Desktop-$release_version-macos-$arch.dmg"
  if [ -n "${ASTER_NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "dist/Aster-Desktop-$release_version-macos-$arch.dmg" --keychain-profile "$ASTER_NOTARY_PROFILE" --wait
    xcrun stapler staple "dist/Aster-Desktop-$release_version-macos-$arch.dmg"
  fi
fi
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then bash scripts/package-source.sh "$source"; fi
python3 -c 'import pathlib,hashlib; d=pathlib.Path("dist"); (d/"checksums.txt").write_text("".join(hashlib.sha256(p.read_bytes()).hexdigest()+"  "+p.name+"\n" for p in sorted(d.iterdir()) if p.is_file() and p.name != "checksums.txt"))'
