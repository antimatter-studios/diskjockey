#!/bin/bash
# Install DiskJockeyAgent as a user LaunchAgent pointing at the DerivedData
# build — no /Applications copy needed, no admin prompt.
# Run once after each build. The agent persists until logout.
set -euo pipefail

AGENT_BIN=$(find ~/Library/Developer/Xcode/DerivedData \
    -name "DiskJockeyAgent" \
    -path "*/Build/Products/Debug/DiskJockey.app/Contents/Library/LaunchAgents/*" \
    -not -path "*Index.noindex*" \
    -print -quit 2>/dev/null)

if [ -z "$AGENT_BIN" ]; then
    echo "ERROR: DiskJockeyAgent not found in DerivedData — build the project first." >&2
    exit 1
fi

PLIST=~/Library/LaunchAgents/com.antimatterstudios.diskjockey.agent.plist

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.antimatterstudios.diskjockey.agent</string>
    <key>MachServices</key>
    <dict>
        <key>com.antimatterstudios.diskjockey.agent</key>
        <true/>
    </dict>
    <key>Program</key>
    <string>$AGENT_BIN</string>
</dict>
</plist>
PLIST

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "Agent loaded: $AGENT_BIN"
launchctl list | grep diskjockey.agent || echo "(not yet visible — give it a second)"
