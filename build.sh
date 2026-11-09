#!/bin/bash
# Builds Resource Monitor.app and installs it to ~/Applications
set -e
cd "$(dirname "$0")"
swift build -c release
APP="build/Resource Monitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/ResourceMonitor "$APP/Contents/MacOS/ResourceMonitor"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Resource Monitor</string>
<key>CFBundleIdentifier</key><string>local.pkaloori.resourcemonitor</string>
<key>CFBundleExecutable</key><string>ResourceMonitor</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"Resource Monitor.app"
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/Resource Monitor.app"
