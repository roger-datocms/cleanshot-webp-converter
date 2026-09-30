#!/bin/zsh
# Builds and installs (or with `uninstall`, removes) the converter as a per-user launchd agent.
set -euo pipefail
cd ${0:A:h}

NAME=cleanshot-webp-converter
LABEL=local.$NAME
PLIST=~/Library/LaunchAgents/$LABEL.plist
BINARY=~/.local/bin/$NAME
LEGACY_LOG=~/Library/Logs/$NAME.log
LOGS="/usr/bin/log stream --style compact --predicate 'subsystem == \"$LABEL\"'"
DOMAIN=gui/$(id -u)

launchctl bootout $DOMAIN/$LABEL 2>/dev/null || true

if [[ ${1:-} == uninstall ]]; then
  rm -f $PLIST $BINARY $LEGACY_LOG
  echo "Uninstalled."
  exit 0
fi

swift build -c release
mkdir -p ${BINARY:h} ${PLIST:h}
cp .build/release/$NAME $BINARY

cat > $PLIST <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BINARY</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap $DOMAIN $PLIST
sleep 1
# Earlier versions logged to a file; unified logging replaced it.
rm -f $LEGACY_LOG
echo "Installed. Live logs: $LOGS"
