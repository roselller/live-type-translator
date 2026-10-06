#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
swift test --disable-sandbox --arch arm64 --cache-path "$PWD/.build/cache" \
  --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
