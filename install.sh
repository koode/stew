#!/usr/bin/env bash
# Builds stew, installs it to ~/.local/bin, runs the daemon as a LaunchAgent and
# installs the Claude Code skill that tells sessions how to call it.
set -euo pipefail
cd "$(dirname "$0")"

label="nl.koode.stew"
bin_dir="$HOME/.local/bin"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

swift build -c release
mkdir -p "$bin_dir" "$HOME/Library/LaunchAgents" "$HOME/.claude/skills/stew"

# Stop the running daemon before its binary is replaced.
launchctl bootout "$domain/$label" 2>/dev/null || true
install -m 755 .build/release/stew "$bin_dir/stew"

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$bin_dir/stew</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/stew.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/stew.log</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$domain" "$plist"
install -m 644 skill/SKILL.md "$HOME/.claude/skills/stew/SKILL.md"

echo "Installed $bin_dir/stew, LaunchAgent $label, skill ~/.claude/skills/stew"
"$bin_dir/stew" keys
