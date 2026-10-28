#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh release
VERSION="$(cat VERSION)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -R build/ClipLine.app "$WORK/"
ln -s /Applications "$WORK/Applications"
hdiutil create -quiet -srcfolder "$WORK" -volname ClipLine -format UDZO "build/ClipLine-$VERSION.dmg"
echo "Built build/ClipLine-$VERSION.dmg"
