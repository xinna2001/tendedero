#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(cat VERSION)"
bash scripts/build-app.sh release
ditto -c -k --sequesterRsrc --keepParent build/ClipLine.app "build/ClipLine-$VERSION-macos-universal.zip"
(cd build && shasum -a 256 "ClipLine-$VERSION-macos-universal.zip" > SHA256SUMS.txt)
echo "Packaged ClipLine $VERSION"
