#!/usr/bin/env bash
# 构建 MeetingScribe.app
#
#   ./build.sh            构建到 ./build/MeetingScribe.app
#   ./build.sh --install  构建并安装到 /Applications
#   MEETINGSCRIBE_SIGN_IDENTITY="Developer ID Application: ..." ./build.sh

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="MeetingScribe"
HELPER_APP_NAME="MeetingScribeAudioHelper"
BUNDLE_ID="com.meetingscribe.app"
VERSION="1.0"
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

BINARY="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || { echo "编译失败：找不到 $BINARY" >&2; exit 1; }

info "打包 app bundle…"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources" \
    "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app/Contents/MacOS"
cp "$BINARY" "$DEST/Contents/MacOS/$APP_NAME"
[ -x "$DEST/Contents/MacOS/$APP_NAME" ] || { echo "打包失败：二进制未就位" >&2; exit 1; }
[ -f "$ICON_FILE" ] || { echo "打包失败：找不到应用图标 $ICON_FILE" >&2; exit 1; }
[ -f "$ENTITLEMENTS_FILE" ] || { echo "打包失败：找不到签名权限文件 $ENTITLEMENTS_FILE" >&2; exit 1; }
cp "$ICON_FILE" "$DEST/Contents/Resources/AppIcon.icns"
cp "$BINARY" "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app/Contents/MacOS/MeetingScribeAudioHelper"

cat > "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MeetingScribeAudioHelper</string>
    <key>CFBundleDisplayName</key><string>MeetingScribe Audio Helper</string>
    <key>CFBundleIdentifier</key><string>com.meetingscribe.audio-helper</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>MeetingScribeAudioHelper</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MeetingScribe Audio Helper 需要读取 BlackHole 虚拟音频输入。</string>
</dict>
</plist>
PLIST

cat > "$DEST/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>会议纪要</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>MeetingScribe 实时字幕需要通过 Audio Helper 读取 BlackHole 虚拟音频输入。</string>
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
        "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app" 2>/dev/null
    codesign --force --options runtime --entitlements "$ENTITLEMENTS_FILE" --sign - \
        "$DEST" 2>/dev/null
else
    # A Developer ID build is ready to submit to Apple's notary service.
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" \
        --sign "$SIGN_IDENTITY" "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app"
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_FILE" \
        --sign "$SIGN_IDENTITY" "$DEST"
fi

if [ "${1:-}" = "--install" ]; then
    TARGET="/Applications/$APP_NAME.app"
    HELPER_TARGET="/Applications/$HELPER_APP_NAME.app"

    # 正在运行的实例会占住可执行文件，rm -rf 删不掉，cp 就会复制进残留目录，
    # 旧二进制原封不动 —— 装完看起来成功，跑起来还是老版本。先退出它。
    if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
        info "检测到 $APP_NAME 正在运行，先退出…"
        osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
        for _ in $(seq 20); do
            pgrep -x "$APP_NAME" > /dev/null 2>&1 || break
            sleep 0.25
        done
        pgrep -x "$APP_NAME" > /dev/null 2>&1 && pkill -x "$APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi
    if pgrep -x "$HELPER_APP_NAME" > /dev/null 2>&1; then
        info "检测到 $HELPER_APP_NAME 正在运行，先退出…"
        pkill -x "$HELPER_APP_NAME" 2>/dev/null || true
        sleep 0.5
    fi

    info "安装到 /Applications…"
    rm -rf "$TARGET"
    [ -e "$TARGET" ] && { echo "无法删除旧版本，请手动退出 $APP_NAME 后重试" >&2; exit 1; }
    cp -R "$DEST" /Applications/
    rm -rf "$HELPER_TARGET"
    cp -R "$DEST/Contents/Helpers/MeetingScribeAudioHelper.app" "$HELPER_TARGET"

    # 自检：装上的必须和刚构建的是同一个二进制
    NEW_SUM=$(shasum -a 256 "$DEST/Contents/MacOS/$APP_NAME" | cut -d' ' -f1)
    GOT_SUM=$(shasum -a 256 "$TARGET/Contents/MacOS/$APP_NAME" 2>/dev/null | cut -d' ' -f1)
    if [ "$NEW_SUM" != "$GOT_SUM" ]; then
        echo "安装校验失败：/Applications 里的二进制与本次构建不一致" >&2
        exit 1
    fi
    codesign --verify --deep --strict "$HELPER_TARGET"

    info "完成 → ${TARGET}（已校验）"
    info "音频 Helper → ${HELPER_TARGET}（已校验）"
else
    info "完成 → $(pwd)/$DEST"
    info "安装到 /Applications：./build.sh --install"
fi
