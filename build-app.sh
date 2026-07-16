#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CACHE="$ROOT/work/cache"
ARM="$ROOT/work/arm"
INTEL="$ROOT/work/intel"
APP="$ROOT/outputs/超强截图.app"
PLIST="$ROOT/AppBundle/Info.plist"
mkdir -p "$CACHE/home" "$CACHE/clang" "$APP/Contents/MacOS" "$APP/Contents/Resources"
export HOME="$CACHE/home" CLANG_MODULE_CACHE_PATH="$CACHE/clang" SWIFTPM_MODULECACHE_OVERRIDE="$CACHE/clang"
cd "$ROOT"

# Every packaged release gets a new patch version and build number.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
NEXT_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
NEXT_BUILD_NUMBER="$((BUILD_NUMBER + 1))"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD_NUMBER" "$PLIST"

swift build -c release --disable-sandbox --scratch-path "$ARM"
swift build -c release --disable-sandbox --scratch-path "$INTEL" --triple x86_64-apple-macosx12.0
lipo -create "$ARM/arm64-apple-macosx/release/SuperScreenshot" "$INTEL/x86_64-apple-macosx/release/SuperScreenshot" -output "$APP/Contents/MacOS/SuperScreenshot"
cp "$PLIST" "$APP/Contents/Info.plist"
if [ -f "$ROOT/AppBundle/Assets/SuperScreenshot.icns" ]; then
    cp "$ROOT/AppBundle/Assets/SuperScreenshot.icns" "$APP/Contents/Resources/SuperScreenshot.icns"
fi
codesign --force --deep --sign - \
    --requirements '=designated => identifier "com.lion.superscreenshot.screenkit"' \
    "$APP"
ZIP="$ROOT/outputs/超强截图-v${NEXT_VERSION}-通用版.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
echo "已生成：$APP"
echo "版本：$NEXT_VERSION ($NEXT_BUILD_NUMBER)"
echo "压缩包：$ZIP"
