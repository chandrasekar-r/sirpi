#!/bin/zsh
# Builds Sirpi.app (formerly AssetForge, then Foundry) into ./build (and optionally installs to /Applications with --install)
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# xcodebuild (not `swift build`): MLX's Metal kernels are only compiled into default.metallib by Xcode's
# build system. Needs the Metal toolchain once: xcodebuild -downloadComponent MetalToolchain
xcodebuild -scheme Sirpi -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/dd -skipMacroValidation -skipPackagePluginValidation -quiet build 2>&1 \
  | grep -v -e CoreSimulator -e "^$" || true
BIN=build/dd/Build/Products/Release
[[ -x "$BIN/Sirpi" ]] || { echo "build failed"; exit 1; }
APP=build/Sirpi.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sirpi" "$APP/Contents/MacOS/Sirpi"
# SwiftPM resource bundles (MLX metallib, tokenizer fallbacks); Bundle.module also searches Resources/.
for b in "$BIN"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
cp -R Resources/web "$APP/Contents/Resources/web"
cp -R Resources/tools "$APP/Contents/Resources/tools"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Sirpi</string>
  <key>CFBundleDisplayName</key><string>Sirpi</string>
  <key>CFBundleIdentifier</key><string>com.rclabs.AssetForge</string>
  <key>CFBundleExecutable</key><string>Sirpi</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSLocalNetworkUsageDescription</key><string>Sirpi talks to your Bambu Lab printer on the local network to show status and send prints.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsArbitraryLoads</key><true/><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "Built $APP"
if [[ "${1:-}" == "--install" ]]; then
  # The bundle ID is unchanged (com.rclabs.AssetForge) so settings and the asset library carry over.
  [[ -d /Applications/AssetForge.app ]] && osascript -e 'tell application "Finder" to delete POSIX file "/Applications/AssetForge.app"' >/dev/null 2>&1
  rm -rf /Applications/Sirpi.app && cp -R "$APP" /Applications/ && echo "Installed to /Applications/Sirpi.app"
fi
