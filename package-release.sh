#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
destination="${1:-$root/build}"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$root/Info.plist")"
archive="$destination/SnipBar-$version.zip"
mkdir -p "$destination"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
SNIPBAR_UNIVERSAL=1 bash "$root/build.sh" "$staging"
/usr/bin/lipo "$staging/SnipBar.app/Contents/MacOS/SnipBar" -verify_arch arm64 x86_64
/usr/bin/ditto -c -k --keepParent "$staging/SnipBar.app" "$archive"
/usr/bin/shasum -a 256 "$archive"
