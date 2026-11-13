#!/usr/bin/env bash
# Removes stew: hooks, daemon, Stew.app, the stew link, skill, shell completion, caches and
# stored approvals.
# Keeps ~/.config/stew and any allow rules stew added to projects' .claude/settings.local.json.
#
#   ./uninstall.sh [--bin-dir DIR] [--app-dir DIR]
#
# A copy ships in the app: ~/Applications/Stew.app/Contents/Resources/uninstall.sh
set -euo pipefail
bin_dir="$HOME/.local/bin"
app_dir="$HOME/Applications"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --bin-dir) bin_dir="$2"; shift ;;
    --app-dir) app_dir="$2"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done
label="nl.koode.stew"

# Tests set STEW_INSTALL_LAUNCHCTL_LOG, so they never stop the real daemon.
launchctl_run() {
  if [[ -n "${STEW_INSTALL_LAUNCHCTL_LOG:-}" ]]; then
    echo "launchctl $*" >> "$STEW_INSTALL_LAUNCHCTL_LOG"
    return 0
  fi
  launchctl "$@"
}

if [[ -x "$bin_dir/stew" ]]; then
  # `stew uninstall` does all of the below. A stew from before that command exits
  # with an error, and the steps below run instead.
  if "$bin_dir/stew" uninstall --bin-dir "$bin_dir" --app-dir "$app_dir"; then
    exit 0
  fi
  "$bin_dir/stew" hooks uninstall || true
  "$bin_dir/stew" completions uninstall 2> /dev/null || true
fi
launchctl_run bootout "gui/$(id -u)/$label" 2> /dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist" "$bin_dir/stew"
rm -rf "$app_dir/Stew.app" "$app_dir/.Stew.app.installing" "$app_dir/.Stew.app.previous" "$app_dir/.stew-update"
rm -rf "$HOME/.claude/skills/stew" "$HOME/Library/Caches/stew" "$HOME/Library/Application Support/stew"
# iPhone pairings live in the login keychain. The installer tests set
# STEW_INSTALL_LAUNCHCTL_LOG and must not touch the real keychain.
if [[ -z "${STEW_INSTALL_LAUNCHCTL_LOG:-}" ]]; then
  while security delete-generic-password -s nl.koode.stew.link > /dev/null 2>&1; do :; done
fi
echo "stew removed. Settings in ~/.config/stew are kept."
