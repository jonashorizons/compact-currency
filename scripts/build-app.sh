#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h:h}"
destination="${1:-$project_dir/build}"
app="$destination/Compact Currency.app"
cd "$project_dir"
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/CompactCurrency" "$app/Contents/MacOS/CompactCurrency"
resource_bundle="$binary_dir/CompactCurrency_CompactCurrency.bundle"
if [[ -d "$resource_bundle" ]]; then
  ditto "$resource_bundle" "$app/Contents/Resources/CompactCurrency_CompactCurrency.bundle"
fi
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Compact Currency</string>
<key>CFBundleDisplayName</key><string>Compact Currency</string>
<key>CFBundleIdentifier</key><string>ai.exique.compactcurrency</string>
<key>CFBundleExecutable</key><string>CompactCurrency</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.2</string>
<key>CFBundleVersion</key><string>4</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
if [[ -f "$project_dir/scripts/AppIcon.icns" ]]; then
  cp "$project_dir/scripts/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
fi
codesign --force --sign - --timestamp=none "$app"
codesign --verify --strict "$app"
print -r -- "$app"
