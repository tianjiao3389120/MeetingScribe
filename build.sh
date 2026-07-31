#!/usr/bin/env bash
# 构建 MeetingScribe.app
#
#   ./build.sh            构建到 ./build/MeetingScribe.app
#   ./build.sh --install  构建并安装到 /Applications

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP_NAME="MeetingScribe"
BUNDLE_ID="com.meetingscribe.app"
VERSION="1.0"
DEST="build/$APP_NAME.app"

info() { printf '\033[36m▸\033[0m %s\n' "$*"; }

info "编译（release）…"
swift build -c release --arch arm64 2>&1 | grep -vE '^\[|warning:|^ *\||^ *`|note:|^$' || true

BINARY="$(swift build -c release --arch arm64 --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || { echo "编译失败：找不到 $BINARY" >&2; exit 1; }

info "打包 app bundle…"
rm -rf "$DEST"
mkdir -p "$DEST/Contents/MacOS" "$DEST/Contents/Resources"
cp "$BINARY" "$DEST/Contents/MacOS/$APP_NAME"

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
    <key>LSMinimumSystemVersion</key><string>14.0</string>
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

# Ad-hoc signature: enough for local use and for the keychain to scope
# credentials to this app. Distribution would need a Developer ID.
info "签名…"
codesign --force --deep --sign - "$DEST" 2>/dev/null

if [ "${1:-}" = "--install" ]; then
    info "安装到 /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$DEST" /Applications/
    info "完成 → /Applications/$APP_NAME.app"
else
    info "完成 → $(pwd)/$DEST"
    info "安装到 /Applications：./build.sh --install"
fi
