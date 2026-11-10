#!/bin/zsh
set -eu
SOURCE_DIR="${0:A:h}"
OUTPUT_DIR="${SOURCE_DIR:h}"
APP="$OUTPUT_DIR/贤者模式.app"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp/}xianzhe-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/cache"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -module-cache-path "$BUILD_DIR/cache" \
  "$SOURCE_DIR/ModeCore.swift" "$SOURCE_DIR/SystemBackend.swift" \
  "$SOURCE_DIR/SelfTests.swift" "$SOURCE_DIR/main.swift" \
  -framework AppKit -framework Carbon -o "$APP/Contents/MacOS/XianZheMode"
cp "$SOURCE_DIR/Info.plist" "$APP/Contents/Info.plist"
if [[ -f "$SOURCE_DIR/Resources/AppIcon.icns" ]]; then
  cp "$SOURCE_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
print -rn 'APPL????' > "$APP/Contents/PkgInfo"
/usr/bin/codesign --force --sign - --identifier local.xianzhe.mode "$APP"
"$APP/Contents/MacOS/XianZheMode" --self-test
print "已构建：$APP"
