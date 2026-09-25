#!/usr/bin/env bash
# 构建 MeetingScribe.app
#
#   ./build.sh                       构建测试版
#   ./build.sh --install             构建并安装测试版
#   ./build.sh --production          构建正式版
#   ./build.sh --install-production  构建并安装正式版
#   MEETINGSCRIBE_SIGN_IDENTITY="Developer ID Application: ..." ./build.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

MODE="${1:-}"
INSTALL=false
DATA_ENVIRONMENT="test"
APP_NAME="MeetingScribe"
EXECUTABLE_NAME="MeetingScribe"
BUNDLE_ID="com.meetingscribe.app"
DISPLAY_NAME="会议纪要 · 测试"
case "$MODE" in
    "") ;;
    --install) INSTALL=true ;;
    --production)
        DATA_ENVIRONMENT="production"
        APP_NAME="MeetingScribe Production"
        EXECUTABLE_NAME="MeetingScribeProduction"
        BUNDLE_ID="com.meetingscribe.app.production"
        DISPLAY_NAME="会议纪要 · 正式"
        ;;
    --install-production)
        INSTALL=true
        DATA_ENVIRONMENT="production"
        APP_NAME="MeetingScribe Production"
        EXECUTABLE_NAME="MeetingScribeProduction"
        BUNDLE_ID="com.meetingscribe.app.production"
        DISPLAY_NAME="会议纪要 · 正式"
        ;;
    *) echo "未知参数：$MODE" >&2; exit 2 ;;
esac
VERSION="${MEETINGSCRIBE_VERSION:-1.0.0}"
BUILD_NUMBER="${MEETINGSCRIBE_BUILD_NUMBER:-1}"
ICON_FILE="Assets/AppIcon.icns"
ENTITLEMENTS_FILE="MeetingScribe.entitlements"
DEST="build/$APP_NAME.app"
SIGN_IDENTITY="${MEETINGSCRIBE_SIGN_IDENTITY:--}"

info() { printf '\033[36m▸\033[0m %s\n' "$*"; }

info "编译（release）…"
BUILD_LOG="$(mktemp -t meetingscribe-build.XXXXXX)"
trap 'rm -f "$BUILD_LOG"' EXIT
if ! swift build -c release --arch arm64 >"$BUILD_LOG" 2>&1; then
    grep -vE '^\[|^ *\||^ *`|note:|^$' "$BUILD_LOG" >&2 || true
    echo "编译失败，完整日志：$BUILD_LOG" >&2
    trap - EXIT
    exit 1
fi
grep -vE '^\[|warning:|^ *\||^ *`|note:|^$' "$BUILD_LOG" || true

BINARY="$(swift build -c release --arch arm64 --show-bin-path)/MeetingScribe"
[ -f "$BINARY" ] || { echo "编译失败：找不到 $BINARY" >&2; exit 1; }

info "打包 app bundle…"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BINARY" "$DEST/Contents/MacOS/$EXECUTABLE_NAME"
[ -x "$DEST/Contents/MacOS/$EXECUTABLE_NAME" ] || { echo "打包失败：二进制未就位" >&2; exit 1; }
[ -f "$ICON_FILE" ] || { echo "打包失败：找不到应用图标 $ICON_FILE" >&2; exit 1; }
[ -f "$ENTITLEMENTS_FILE" ] || { echo "打包失败：找不到签名权限文件 $ENTITLEMENTS_FILE" >&2; exit 1; }
cp "$ICON_FILE" "$DEST/Contents/Resources/AppIcon.icns"
cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
    <key>MeetingScribeDataEnvironment</key><string>$DATA_ENVIRONMENT</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>本地处理会议录音与录像</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>会议录像或录音</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
                <string>public.audio</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

info "签名…"
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signature is sufficient for local use.
    codesign --force --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign - \
        "$DEST" 2>/dev/null
else
    # A Developer ID build is ready to submit to Apple's notary service.
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" \
        --sign "$SIGN_IDENTITY" "$DEST"
fi

if [ "$INSTALL" = true ]; then
    TARGET="/Applications/$APP_NAME.app"
    HELPER_TARGET="/Applications/MeetingScribeAudioHelper.app"
    LEGACY_HELPER_AGENT="$HOME/Library/LaunchAgents/com.meetingscribe.audio-helper.plist"

    # Older builds registered a KeepAlive audio helper. If left loaded it will
    # continuously relaunch the main binary with obsolete server arguments.
    launchctl bootout "gui/$(id -u)/com.meetingscribe.audio-helper" 2>/dev/null || true
    rm -f "$LEGACY_HELPER_AGENT"

    # 正在运行的实例会占住可执行文件，rm -rf 删不掉，cp 就会复制进残留目录，
    # 旧二进制原封不动 —— 装完看起来成功，跑起来还是老版本。先退出它。
    if pgrep -x "$EXECUTABLE_NAME" > /dev/null 2>&1; then
        info "检测到 $APP_NAME 正在运行，先退出…"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" 2>/dev/null || true
        for _ in $(seq 20); do
            pgrep -x "$EXECUTABLE_NAME" > /dev/null 2>&1 || break
            sleep 0.25
        done
        pgrep -x "$EXECUTABLE_NAME" > /dev/null 2>&1 && pkill -x "$EXECUTABLE_NAME" 2>/dev/null || true
        sleep 0.5
    fi
    if pgrep -x "MeetingScribeAudioHelper" > /dev/null 2>&1; then
        info "检测到旧 Audio Helper 正在运行，先退出并清理…"
        pkill -x "MeetingScribeAudioHelper" 2>/dev/null || true
        sleep 0.5
    fi

    info "安装到 /Applications…"
    rm -rf "$TARGET"
    [ -e "$TARGET" ] && { echo "无法删除旧版本，请手动退出 $APP_NAME 后重试" >&2; exit 1; }
    cp -R "$DEST" /Applications/
    rm -rf "$HELPER_TARGET"
    # 自检：装上的必须和刚构建的是同一个二进制
    NEW_SUM=$(shasum -a 256 "$DEST/Contents/MacOS/$EXECUTABLE_NAME" | cut -d' ' -f1)
    GOT_SUM=$(shasum -a 256 "$TARGET/Contents/MacOS/$EXECUTABLE_NAME" 2>/dev/null | cut -d' ' -f1)
    if [ "$NEW_SUM" != "$GOT_SUM" ]; then
        echo "安装校验失败：/Applications 里的二进制与本次构建不一致" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$TARGET"

    info "完成 → ${TARGET}（已校验）"
    info "实时字幕与 Audio Helper → 已移除"
else
    info "完成 → $(pwd)/$DEST"
    if [ "$DATA_ENVIRONMENT" = "production" ]; then
        info "安装到 /Applications：./build.sh --install-production"
    else
        info "安装到 /Applications：./build.sh --install"
    fi
fi
