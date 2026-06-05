#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="CodexQuotaViewer"
APP_VERSION="1.3.2"
APP_BUILD="132"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
ICON_ICNS="$ROOT_DIR/.build/AppIcon.icns"
APP_ICON_ASSETS_DIR="$APP_DIR/Contents/Resources/AppIconAssets"
SESSION_MANAGER_RESOURCES_DIR="$APP_DIR/Contents/Resources/SessionManager"

clean_bundle_metadata_before_signing() {
  local bundle_dir="$1"

  find "$bundle_dir" \( -name '._*' -o -name '.DS_Store' \) -delete
  chmod -R u+w "$bundle_dir" 2>/dev/null || true
  xattr -cr "$bundle_dir" 2>/dev/null || true
  xattr -dr com.apple.FinderInfo "$bundle_dir" 2>/dev/null || true
  xattr -dr 'com.apple.fileprovider.fpfs#P' "$bundle_dir" 2>/dev/null || true
  xattr -dr com.apple.provenance "$bundle_dir" 2>/dev/null || true
  xattr -c "$bundle_dir" 2>/dev/null || true
  xattr -d com.apple.FinderInfo "$bundle_dir" 2>/dev/null || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$bundle_dir" 2>/dev/null || true
}

sign_app_bundle() {
  local source_app_dir="$1"
  local signing_root="${TMPDIR:-/tmp}/codex-quota-viewer-signing-$$"
  local signing_app_dir="$signing_root/$APP_NAME.app"

  rm -rf "$signing_root"
  mkdir -p "$signing_root"
  ditto --noextattr "$source_app_dir" "$signing_app_dir"
  clean_bundle_metadata_before_signing "$signing_app_dir"
  xattr -c "$signing_app_dir" 2>/dev/null || true
  codesign --force --deep --sign - "$signing_app_dir"

  rm -rf "$source_app_dir"
  ditto --noextattr "$signing_app_dir" "$source_app_dir"
  clean_bundle_metadata_before_signing "$source_app_dir"
  rm -rf "$signing_root"
}

cd "$ROOT_DIR"

swift package clean
swift build -c release --product CodexQuotaViewer
BIN_DIR="$(swift build -c release --show-bin-path)"
swift scripts/generate-app-icon.swift "$ROOT_DIR"
xattr -c "$ROOT_DIR/dist/CodexQuotaViewer-icon-preview.png" 2>/dev/null || true
rm -f "$ICON_ICNS"
iconutil -c icns "$ICONSET_DIR" -o "$ICON_ICNS"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_ICON_ASSETS_DIR"

cp "$BIN_DIR/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ICON_ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Sources/CodexQuotaViewer/Resources/openai-blossom-dark.svg" "$APP_ICON_ASSETS_DIR/openai-blossom-dark.svg"
cp "$ROOT_DIR/Sources/CodexQuotaViewer/Resources/openai-blossom-light.svg" "$APP_ICON_ASSETS_DIR/openai-blossom-light.svg"
"$ROOT_DIR/scripts/build-session-manager.sh" "$SESSION_MANAGER_RESOURCES_DIR"
strip -S -x "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Codex Quota Viewer</string>
    <key>CFBundleExecutable</key>
    <string>CodexQuotaViewer</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>dev.codex.quotaviewer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Codex Quota Viewer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

clean_bundle_metadata_before_signing "$APP_DIR"

if command -v codesign >/dev/null 2>&1; then
  sign_app_bundle "$APP_DIR"
else
  echo "warning: codesign is unavailable; skipping ad-hoc signing." >&2
fi

clean_bundle_metadata_before_signing "$APP_DIR"

echo "Built app: $APP_NAME.app"
