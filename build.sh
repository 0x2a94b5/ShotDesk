#!/bin/bash
# 构建 ShotDesk.app（不依赖 Xcode GUI）
set -euo pipefail

cd "$(dirname "$0")"
APP_NAME="ShotDesk"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
ICON_SOURCE="Resources/AppIcon.png"
ICON_OUTPUT="Resources/AppIcon.icns"

INSTALL=false
case "${1:-}" in
    "") ;;
    --install) INSTALL=true ;;
    *)
        echo "用法: $0 [--install]" >&2
        exit 2
        ;;
esac

if [ ! -f "$ICON_OUTPUT" ] || [ "$ICON_SOURCE" -nt "$ICON_OUTPUT" ]; then
    echo "==> 生成 App Icon"
    swift tools/MakeIcon.swift "$ICON_SOURCE" "$BUILD_DIR/AppIcon.iconset"
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$ICON_OUTPUT"
fi

echo "==> 编译 (release)"
swift build -c release

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ICON_OUTPUT" "$APP/Contents/Resources/AppIcon.icns"

# 有自签名证书就用证书签（授权绑证书，重新编译不掉权限），
# 没有就退回 ad-hoc（授权绑二进制哈希，每次重新编译都要重新授权）
CERT_NAME="ShotDesk Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "==> 签名 (证书: $CERT_NAME)"
    codesign --force --deep --sign "$CERT_NAME" "$APP"
    SIGN_MODE="证书签名，重新编译不会让屏幕录制授权失效"
else
    echo "==> 签名 (ad-hoc)"
    codesign --force --deep --sign - "$APP"
    SIGN_MODE="ad-hoc 签名，每次重新编译后都要重新授权屏幕录制（跑 ./make-cert.sh 可一劳永逸解决）"
fi
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true

# 构建和安装明确分开，避免普通构建意外覆盖正在使用的版本。
INSTALLED="$HOME/Applications/$APP_NAME.app"
if [ "$INSTALL" = true ]; then
    echo "==> 安装到 ~/Applications"
    rm -rf "$INSTALLED"
    mkdir -p "$HOME/Applications"
    cp -R "$APP" "$INSTALLED"
    # Finder/Launchpad 有时不认新图标，碰一下时间戳催它刷新
    touch "$INSTALLED"
    echo "    $INSTALLED"
fi

echo ""
echo "完成: $APP"
echo "签名: $SIGN_MODE"
echo "启动:  open $APP"
echo "安装:  ./build.sh --install"
echo "重置屏幕录制权限(改完代码重新编译后如果抓到空白图就跑这条):"
echo "  tccutil reset ScreenCapture com.shotdesk.app"
