#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache"
swift build -c release --disable-sandbox
app_path="$PWD/dist/Impulse.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/LauncherApp "$app_path/Contents/MacOS/Impulse"
cp packaging/Info.plist "$app_path/Contents/Info.plist"
cp THIRD_PARTY_NOTICES.md "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp .build/release/launcherctl dist/launcherctl
codesign --force --sign - --identifier io.github.aaqifz.impulse "$app_path"
codesign --verify --strict "$app_path"
echo "Built: $app_path"
