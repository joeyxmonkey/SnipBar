#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$HOME/Applications}"
mkdir -p "$destination"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
bundle="$staging/SnipBar.app"
mkdir -p "$bundle/Contents/MacOS"
cp "$root/Info.plist" "$bundle/Contents/Info.plist"

if [[ "${SNIPBAR_UNIVERSAL:-0}" == 1 ]]; then
    swiftc -O -warnings-as-errors -target arm64-apple-macos14.0 \
        "$root"/Sources/*.swift -o "$staging/SnipBar-arm64"
    swiftc -O -warnings-as-errors -target x86_64-apple-macos14.0 \
        "$root"/Sources/*.swift -o "$staging/SnipBar-x86_64"
    /usr/bin/lipo -create "$staging/SnipBar-arm64" "$staging/SnipBar-x86_64" \
        -output "$bundle/Contents/MacOS/SnipBar"
else
    swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
        "$root"/Sources/*.swift -o "$bundle/Contents/MacOS/SnipBar"
fi
/usr/bin/codesign --force --sign - --identifier com.snipbar.capture "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$destination/SnipBar.app"
printf '%s\n' "$destination/SnipBar.app"
