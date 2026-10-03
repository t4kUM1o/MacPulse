#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ -x /Library/Developer/CommandLineTools/usr/bin/clang && -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]]; then
  compiler=/Library/Developer/CommandLineTools/usr/bin/clang
  sdk=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
else
  compiler="$(xcrun --find clang)"
  sdk="$(xcrun --show-sdk-path)"
fi
mkdir -p build dist
for app_name in MacPulse ChatGPTUsage; do
  bundle="build/$app_name.app/Contents"
  mkdir -p "$bundle/MacOS" "$bundle/Resources"
  cp "$app_name-Info.plist" "$bundle/Info.plist"
  source_file=main.m
  if [[ "$app_name" == ChatGPTUsage ]]; then source_file=usage.m; fi
  "$compiler" -fobjc-arc -Wall -Wextra -arch x86_64 -arch arm64 -isysroot "$sdk" -mmacosx-version-min=13.0 -framework Cocoa -framework IOKit -framework ServiceManagement "$source_file" -o "$bundle/MacOS/$app_name"
  codesign --force --sign - "build/$app_name.app"
  codesign --verify --strict "build/$app_name.app"
  ditto -c -k --keepParent "build/$app_name.app" "dist/$app_name.zip"
done
