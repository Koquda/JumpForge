#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
scratch_directory="${JUMPFORGE_SCRATCH_PATH:-/private/tmp/jumpforge-verification-build}"
export CLANG_MODULE_CACHE_PATH="$scratch_directory/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$scratch_directory/swift-module-cache"
plugin="$(xcrun --find swift | sed 's@/bin/swift$@@')/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$plugin" ]; then
    swift test --disable-sandbox --scratch-path "$scratch_directory" -Xswiftc -load-plugin-library -Xswiftc "$plugin"
else
    swift test --scratch-path "$scratch_directory"
fi
plutil -lint iOS/Info.plist iOS/JumpForge.xcodeproj/project.pbxproj Resources/macOS-Info.plist
if git ls-files | rg '\.(js|jsx|mjs|cjs|ts|tsx|py)$'; then
    printf '%s\n' 'Prohibited-language source found.' >&2
    exit 1
fi
