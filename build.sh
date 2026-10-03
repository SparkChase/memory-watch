#!/bin/zsh
set -euo pipefail
project_dir="${0:A:h}"
app_dir="$project_dir/内存哨兵.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$project_dir/Resources/MemoryWatch.icns" "$app_dir/Contents/Resources/MemoryWatch.icns"
cp "$project_dir/Resources/MemoryAlert.aiff" "$app_dir/Contents/Resources/MemoryAlert.aiff"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement \
  "$project_dir/Sources/Core.swift" "$project_dir/Sources/Monitor.swift" \
  "$project_dir/Sources/Panel.swift" "$project_dir/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/MemoryWatch"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MemoryWatch</string>
<key>CFBundleIdentifier</key><string>local.trace.MemoryWatch</string>
<key>CFBundleName</key><string>内存哨兵</string>
<key>CFBundleIconFile</key><string>MemoryWatch</string>
<key>CFBundleDisplayName</key><string>内存哨兵</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
<key>CFBundleLocalizations</key><array><string>zh_CN</string><string>en</string></array>
</dict></plist>
PLIST
codesign --force --sign - --identifier local.trace.MemoryWatch "$app_dir"
codesign --verify --strict "$app_dir"
print "Built: $app_dir"
