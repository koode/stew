#!/usr/bin/env bash
# Removes stew: hooks, daemon, binary, skill, caches and stored approvals.
# Keeps ~/.config/stew and any allow rules stew added to projects' .claude/settings.local.json.
#
#   ./uninstall.sh [--bin-dir DIR]
set -euo pipefail
bin_dir="$HOME/.local/bin"
[[ "${1:-}" == "--bin-dir" ]] && bin_dir="$2"
label="nl.koode.stew"

if [[ -x "$bin_dir/stew" ]]; then
  "$bin_dir/stew" hooks uninstall || true
fi
launchctl bootout "gui/$(id -u)/$label" 2> /dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$bin_dir/stew"
rm -rf "$HOME/.claude/skills/stew" "$HOME/Library/Caches/stew" "$HOME/Library/Application Support/stew"
echo "stew removed. Settings in ~/.config/stew are kept."
