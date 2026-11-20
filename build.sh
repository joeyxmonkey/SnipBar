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

swiftc -O -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
    "$root"/Sources/*.swift -o "$bundle/Contents/MacOS/SnipBar"
/usr/bin/codesign --force --sign - --identifier com.snipbar.capture "$bundle"
/usr/bin/codesign --verify --strict "$bundle"
/usr/bin/ditto "$bundle" "$destination/SnipBar.app"
printf '%s\n' "$destination/SnipBar.app"
