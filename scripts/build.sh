#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
identity_file="$PWD/signing.local"
if [[ ! -f "$identity_file" ]]; then
  printf 'Missing signing.local. Follow the signing instructions in README.md; ad-hoc signing is disabled.\n' >&2
  exit 1
fi
identity="$(cat "$identity_file")"
if [[ -z "$identity" || "$identity" == '-' || "$identity" == *$'\n'* ]]; then
  printf 'signing.local must contain one exact certificate identity name.\n' >&2
  exit 1
fi
identities="$(/usr/bin/security find-identity -v -p codesigning)"
if [[ "$identities" != *"\"$identity\""* ]]; then
  printf 'No valid signing identity named "%s". Check its private key, expiry, and Code Signing trust in Keychain Access.\n' "$identity" >&2
  exit 1
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
configuration="${CONFIGURATION:-debug}"
swift build --disable-sandbox --arch arm64 -c "$configuration" \
  --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security"
app="$PWD/build/TranslateBar.app"
mkdir -p "$app/Contents/MacOS"
binary_directory="$(swift build --disable-sandbox --arch arm64 -c "$configuration" \
  --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security" --show-bin-path)"
cp "$binary_directory/TranslateBar" "$app/Contents/MacOS/TranslateBar"
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/bin/codesign --force --sign "$identity" --options runtime --timestamp=none "$app"
/usr/bin/codesign --verify --strict "$app"
printf 'Built %s\n' "$app"
