#!/bin/bash
# 把 SwiftPM 产物打包成可双击运行的 Lumi.app（含图标、动态框架、ad-hoc 签名）。
#
# 前置：
#   swift build -c release                                   # x86_64
#   swift build -c release --triple arm64-apple-macosx15.0   # arm64（可选，用于通用包）
#
# 用法：Scripts/package-app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="0.1.0"
DIST="dist"
APP="$DIST/Lumi.app"
X86=".build/release/Lumi"
ARM=".build/arm64-apple-macosx/release/Lumi"

echo "== 0. 清理 =="
rm -rf "$DIST"
mkdir -p "$DIST"

echo "== 1. 图标 =="
swift Scripts/make-icon.swift "$DIST"
iconutil -c icns "$DIST/AppIcon.iconset" -o "$DIST/AppIcon.icns"

echo "== 2. App 结构 =="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

echo "== 3. 可执行文件 =="
test -f "$X86" || { echo "缺少 x86_64 二进制：$X86（先跑 swift build -c release）"; exit 1; }
if [ -f "$ARM" ]; then
    lipo -create "$X86" "$ARM" -output "$APP/Contents/MacOS/Lumi"
    echo "   通用包：x86_64 + arm64"
else
    cp "$X86" "$APP/Contents/MacOS/Lumi"
    echo "   仅 x86_64（Apple Silicon 通过 Rosetta 运行）"
fi
chmod +x "$APP/Contents/MacOS/Lumi"

echo "== 4. 动态框架（AetherEngine 的 FFmpeg 等）=="
FRAMEWORK_SRC=""
for candidate in .build/release .build/x86_64-apple-macosx/release .build/arm64-apple-macosx/release .build/debug; do
    if compgen -G "$candidate/*.framework" > /dev/null 2>&1; then
        FRAMEWORK_SRC="$candidate"
        break
    fi
done
if [ -z "$FRAMEWORK_SRC" ]; then
    echo "找不到动态框架，请先构建"; exit 1
fi
echo "   来源：$FRAMEWORK_SRC"
cp -R "$FRAMEWORK_SRC"/*.framework "$APP/Contents/Frameworks/"

# 让可执行文件从 bundle 内加载框架
if ! otool -l "$APP/Contents/MacOS/Lumi" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Lumi"
fi

echo "== 5. Info.plist =="
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Lumi</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>io.github.mikanshanghai.lumi</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Lumi</string>
    <key>CFBundleDisplayName</key><string>Lumi</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT License © 2026 Lumi Contributors</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST
cp "$DIST/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "== 6. 签名（ad-hoc）=="
for fw in "$APP/Contents/Frameworks/"*.framework; do
    codesign --force --sign - "$fw" >/dev/null 2>&1 || true
done
codesign --force --sign - "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | tail -2

echo "== 7. 打包 =="
ditto -c -k --keepParent "$APP" "$DIST/Lumi-$VERSION-macos.zip"
ls -lah "$DIST"
echo ""
echo "完成：$APP"
echo "  lipo: $(lipo -archs "$APP/Contents/MacOS/Lumi")"
