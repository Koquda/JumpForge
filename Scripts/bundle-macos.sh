#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
configuration="${1:-release}"
scratch_directory="${JUMPFORGE_SCRATCH_PATH:-/private/tmp/jumpforge-native-build}"
export CLANG_MODULE_CACHE_PATH="$scratch_directory/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_directory/swift-module-cache"
swift build --disable-sandbox --scratch-path "$scratch_directory" -c "$configuration" --product JumpForge
binary_directory="$(swift build --disable-sandbox --scratch-path "$scratch_directory" -c "$configuration" --show-bin-path)"
application_directory="$PWD/.build/JumpForge.app"
mkdir -p "$application_directory/Contents/MacOS" "$application_directory/Contents/Resources"
cp "$binary_directory/JumpForge" "$application_directory/Contents/MacOS/JumpForge"
cp Resources/macOS-Info.plist "$application_directory/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$application_directory/Contents/Resources/AppIcon.icns"; fi
xattr -cr "$application_directory"
codesign --force --sign - "$application_directory"
printf '%s\n' "$application_directory"
