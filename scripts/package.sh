#!/bin/bash
# 构建 CCBar.app 并打成 DMG。
#
# 用法: scripts/package.sh [版本号] [--universal]
#   版本号     缺省依次取: 命令行参数 → 最近 git tag（去 v 前缀）→ 现有 Info.plist → 1.1.0
#   --universal 同时编译 arm64 + x86_64（GitHub Actions 发布用；本机调试默认 arm64）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
UNIVERSAL=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    *) if [ -z "$VERSION" ]; then VERSION="$arg"; fi ;;
  esac
done

if [ -z "$VERSION" ]; then
  VERSION="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  VERSION="${VERSION#v}"
fi
if [ -z "$VERSION" ] && [ -f CCBar.app/Contents/Info.plist ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' CCBar.app/Contents/Info.plist 2>/dev/null || true)"
fi
VERSION="${VERSION:-1.1.0}"

ARCH="arm64"
BUILD_ARGS=(-c release)
if [ "$UNIVERSAL" = "1" ]; then
  ARCH="universal"
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> swift build ${BUILD_ARGS[*]}"
swift build "${BUILD_ARGS[@]}"

# 产物路径：单架构在 .build/release；多架构（--arch ... --arch ...）在
# .build/apple/Products/Release；本地若配置了自定义 scratch-path（.build/out）则在那边。
# universal 模式下用 lipo 校验确实含 x86_64，避免捡到过期的单架构产物。
BIN=""
FALLBACK_BIN=""
for p in .build/release/CCBar .build/apple/Products/Release/CCBar .build/out/Products/Release/CCBar; do
  [ -f "$p" ] || continue
  if [ "$UNIVERSAL" = "1" ]; then
    if lipo -archs "$p" 2>/dev/null | grep -q x86_64; then
      BIN="$p"; break
    fi
    [ -z "$FALLBACK_BIN" ] && FALLBACK_BIN="$p"
  else
    BIN="$p"; break
  fi
done
if [ -z "$BIN" ]; then
  if [ -n "$FALLBACK_BIN" ]; then
    echo "警告: 未找到 universal 产物，使用已有的单架构产物" >&2
    BIN="$FALLBACK_BIN"
  else
    echo "错误: 找不到构建产物" >&2
    exit 1
  fi
fi

APP="CCBar.app"

echo "==> 组装 $APP (v$VERSION $ARCH)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>        <string>CCBar</string>
    <key>CFBundleExecutable</key>         <string>CCBar</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>CFBundleIdentifier</key>         <string>com.bmfish.ccbar-native</string>
    <key>CFBundleName</key>               <string>CCBar</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/CCBar"
if [ -f "Resources/AppIcon.icns" ]; then
  cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
  echo "    (未找到 Resources/AppIcon.icns，打包为无图标 app)"
fi

echo "==> codesign (ad-hoc)"
codesign --force --deep -s - "$APP"

DMG="CCBar-$VERSION-$ARCH.dmg"
echo "==> hdiutil 打包 $DMG (含 Applications 快捷方式，拖拽即装)"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname CCBar -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

echo "✅ 完成: $DMG"
