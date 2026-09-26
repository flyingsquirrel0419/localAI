#!/usr/bin/env bash
# Fetch the NodeMobile.xcframework binary needed to build the iOS app.
# Mirrors the CI step in .github/workflows/ci.yml — run this once before
# xcodegen / xcodebuild. The framework is ~51 MB (zip); it is NOT committed
# to the repo.
set -euo pipefail

VERSION="18.20.4"
DEST="App/Frameworks"

if [ -d "${DEST}/NodeMobile.xcframework" ]; then
  echo "NodeMobile.xcframework already present at ${DEST}/NodeMobile.xcframework"
  exit 0
fi

mkdir -p "${DEST}"
echo "Downloading nodejs-mobile v${VERSION} (iOS)…"
curl -sSfL -o /tmp/nodejs-mobile-ios.zip \
  "https://github.com/nodejs-mobile/nodejs-mobile/releases/download/v${VERSION}/nodejs-mobile-v${VERSION}-ios.zip"
unzip -q /tmp/nodejs-mobile-ios.zip 'NodeMobile.xcframework/*' -d "${DEST}"
rm /tmp/nodejs-mobile-ios.zip

# Sanity check.
if [ ! -f "${DEST}/NodeMobile.xcframework/ios-arm64/NodeMobile.framework/Headers/NodeMobile.h" ]; then
  echo "error: NodeMobile.framework/Headers/NodeMobile.h missing after unzip" >&2
  exit 1
fi
echo "Installed NodeMobile.xcframework to ${DEST}/"
