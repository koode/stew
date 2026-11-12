#!/usr/bin/env bash
# Installs Stew for the current user. No admin rights needed.
#
#   curl -fsSL https://releases.stewcli.com/install.sh | bash
#   curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks
#
# What it installs:
#   ~/Applications/Stew.app                       the daemon and the command line tool
#   ~/.local/bin/stew                             a link to the tool inside Stew.app
#   ~/Library/LaunchAgents/nl.koode.stew.plist    starts the daemon at login
#   ~/.claude/skills/stew                         the Claude Code skill, if ~/.claude exists
#
# Options:
#   --with-hooks     also ask in stew when Claude Code's auto mode blocks a call
#   --no-skill       skip the Claude Code skill
#   --bin-dir DIR    put the stew link in DIR instead of ~/.local/bin
#   --app-dir DIR    put Stew.app in DIR instead of ~/Applications
#   --app PATH       install this Stew.app instead of the latest release. ./install.sh
#                    uses it after a source build; the Developer ID check is skipped.
#
# Run it again to update. An older install with a plain binary at ~/.local/bin/stew
# is replaced in place. Claude Code hooks call ~/.local/bin/stew, so they keep working.
# To remove Stew: ~/Applications/Stew.app/Contents/Resources/uninstall.sh
#
# Tests set STEW_INSTALL_LAUNCHCTL_LOG to a file: launchctl calls are then written
# there instead of run, so a test never stops or starts the real daemon.
set -euo pipefail

manifest_url="${STEW_UPDATE_URL:-https://releases.stewcli.com/latest.json}"
team_id="PXD36584ME"
label="nl.koode.stew"

with_hooks=0
with_skill=1
bin_dir="$HOME/.local/bin"
app_dir="$HOME/Applications"
local_app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hooks) with_hooks=1 ;;
    --no-skill) with_skill=0 ;;
    --bin-dir) bin_dir="$2"; shift ;;
    --app-dir) app_dir="$2"; shift ;;
    --app) local_app="$2"; shift ;;
    -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "stew: unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

step() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fail() { printf 'stew: %s\n' "$*" >&2; exit 1; }

launchctl_run() {
  if [[ -n "${STEW_INSTALL_LAUNCHCTL_LOG:-}" ]]; then
    echo "launchctl $*" >> "$STEW_INSTALL_LAUNCHCTL_LOG"
    return 0
  fi
  launchctl "$@"
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Stew runs on macOS only."
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 14 ]] || fail "Stew needs macOS 14 or later. This Mac has $macos_version."

work="$(mktemp -d "${TMPDIR:-/tmp}/stew-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -n "$local_app" ]]; then
  [[ -x "$local_app/Contents/MacOS/stew" ]] || fail "$local_app is not a Stew.app"
  source_app="$local_app"
else
  fail "downloading a release is not available yet; use --app PATH"
fi

app="$app_dir/Stew.app"
link="$bin_dir/stew"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"

mkdir -p "$app_dir" "$bin_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

step "Stopping the running daemon"
launchctl_run bootout "$domain/$label" 2> /dev/null || true

step "Installing Stew $version in $app_dir"
staging="$app_dir/.Stew.app.installing"
previous="$app_dir/.Stew.app.previous"
rm -rf "$staging" "$previous"
ditto "$source_app" "$staging"
if [[ -e "$app" ]]; then
  mv "$app" "$previous"
fi
if ! mv "$staging" "$app"; then
  [[ -e "$previous" ]] && mv "$previous" "$app"
  fail "could not move Stew.app into $app_dir; the previous version is back in place"
fi
rm -rf "$previous"

# An install from before Stew.app put the binary itself here. Replace it with a
# link, so the path that hooks and scripts call stays the same.
if [[ -e "$link" && ! -L "$link" ]]; then
  note "Replacing the old binary at $link with a link into Stew.app."
  rm -f "$link"
fi
ln -sfn "$app/Contents/MacOS/stew" "$link"
note "$link -> $app/Contents/MacOS/stew"

step "Starting the daemon (LaunchAgent $label)"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key>
  <array><string>$app/Contents/MacOS/stew</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/stew.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/stew.log</string>
</dict>
</plist>
PLIST
# launchd can take a moment to let go of the job it just stopped.
started=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if launchctl_run bootstrap "$domain" "$plist" 2> /dev/null; then started=1; break; fi
  sleep 0.5
done
[[ $started -eq 1 ]] || fail "launchctl could not start $plist. Try: launchctl bootstrap $domain $plist"

if [[ $with_skill -eq 1 ]]; then
  if [[ -d "$HOME/.claude" ]]; then
    mkdir -p "$HOME/.claude/skills/stew"
    install -m 644 "$app/Contents/Resources/skill/SKILL.md" "$HOME/.claude/skills/stew/SKILL.md"
    step "Installed the Claude Code skill in ~/.claude/skills/stew"
  else
    note "No ~/.claude folder, so the Claude Code skill was skipped."
  fi
fi

if [[ $with_hooks -eq 1 ]]; then
  step "Installing the Claude Code hooks"
  "$link" hooks install
fi

echo
echo "Installed $("$link" version)."
command -v claude > /dev/null || note "The claude command is not on PATH. The risk check and the auto mode hooks need it."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) note "$bin_dir is not on PATH. Add it to your shell profile, or call stew by its full path." ;;
esac
echo
"$link" keys
echo
echo "Try it: stew notify \"stew works\" --body \"Close this with ⌘. or ⌘↩\""
