#!/usr/bin/env bash
# Removes everything install.sh added. Leaves ~/.config/stew alone.
set -euo pipefail
label="nl.koode.stew"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$HOME/.local/bin/stew"
rm -rf "$HOME/.claude/skills/stew" "$HOME/Library/Caches/stew" "$HOME/Library/Application Support/stew"
echo "stew removed"
