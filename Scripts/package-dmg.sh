#!/bin/zsh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/Scripts/Info.plist")"
destination="$(dirname "$root")"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
"$root/Scripts/build-app.sh" release
ditto "$destination/BiliSwift.app" "$stage/BiliSwift.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname BiliSwift -srcfolder "$stage" -ov -format UDZO "$destination/BiliSwift-$version.dmg"
hdiutil verify "$destination/BiliSwift-$version.dmg"
