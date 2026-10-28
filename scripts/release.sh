#!/bin/zsh
# Archives Good Alarm and uploads it to App Store Connect, where it appears in TestFlight
# and can be submitted for review. The app record must already exist in App Store Connect.
#
# Usage: TEAM_ID=XXXXXXXXXX scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TEAM_ID:?Set TEAM_ID to your Apple Developer team ID}"

ARCHIVE=build/GoodAlarm.xcarchive
OPTIONS=build/ExportOptions.plist

xcodegen generate
xcodebuild archive \
  -project GoodAlarm.xcodeproj -scheme GoodAlarm -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" -allowProvisioningUpdates

mkdir -p build
cat > "$OPTIONS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>destination</key><string>upload</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><true/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" -exportPath build/export \
  -allowProvisioningUpdates
