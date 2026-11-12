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
# The download is checked before anything changes: size and sha256 from latest.json,
# then the code signature, which must be Koode's Developer ID (team PXD36584ME) and
# notarized. Run it again to update. An older install with a plain binary at
# ~/.local/bin/stew is replaced in place. Claude Code hooks call ~/.local/bin/stew,
# so they keep working. To remove Stew: stew uninstall
#
# For tests only: STEW_UPDATE_URL points at another latest.json,
# STEW_UPDATE_SKIP_TEAM_CHECK=1 accepts ad hoc signed builds, and
# STEW_INSTALL_LAUNCHCTL_LOG makes launchctl calls go to that file instead of
# running, so a test never stops or starts the real daemon.
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
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Reads one field of the downloaded latest.json. plutil reads JSON and ships with macOS.
manifest_field() {
  plutil -extract "$1" raw -o - "$work/latest.json" 2> /dev/null || fail "latest.json has no $1"
}

# 0 when macOS version $1 is at least $2 (both X.Y or X.Y.Z).
macos_at_least() {
  local IFS=.
  local -a have=($1) need=($2)
  local index
  for index in 0 1 2; do
    local left="${have[$index]:-0}" right="${need[$index]:-0}"
    if (( left > right )); then return 0; fi
    if (( left < right )); then return 1; fi
  done
  return 0
}

if [[ -n "$local_app" ]]; then
  [[ -x "$local_app/Contents/MacOS/stew" ]] || fail "$local_app is not a Stew.app"
  source_app="$local_app"
else
  command -v curl > /dev/null || fail "curl is missing"
  step "Looking up the latest release"
  curl -fsSL "$manifest_url" -o "$work/latest.json" || fail "could not download $manifest_url"
  release_version="$(manifest_field version)"
  archive_url="$(manifest_field archive.url)"
  archive_sha256="$(manifest_field archive.sha256)"
  archive_size="$(manifest_field archive.size)"
  minimum_macos="$(manifest_field minimumMacOS)"
  macos_at_least "$macos_version" "$minimum_macos" \
    || fail "Stew $release_version needs macOS $minimum_macos or later. This Mac has $macos_version."

  step "Downloading Stew $release_version"
  curl -fSL --progress-bar "$archive_url" -o "$work/Stew.zip" || fail "could not download $archive_url"
  actual_size="$(stat -f%z "$work/Stew.zip")"
  [[ "$actual_size" == "$archive_size" ]] || fail "the download is $actual_size bytes, expected $archive_size. Try again."
  actual_sha256="$(shasum -a 256 "$work/Stew.zip" | cut -d' ' -f1)"
  [[ "$actual_sha256" == "$archive_sha256" ]] || fail "the download's sha256 is $actual_sha256, expected $archive_sha256. Try again."
  note "Size and sha256 match."

  ditto -x -k "$work/Stew.zip" "$work/unzipped" || fail "could not unzip the download"
  source_app="$work/unzipped/Stew.app"
  [[ -x "$source_app/Contents/MacOS/stew" ]] || fail "the download holds no Stew.app"
  unzipped_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"
  [[ "$unzipped_version" == "$release_version" ]] || fail "the download is version $unzipped_version, expected $release_version"

  step "Checking the code signature"
  codesign --verify --deep --strict "$source_app" 2> /dev/null || fail "Stew.app's code signature is not valid"
  # Tests install ad hoc signed builds and set this; a real install always checks.
  if [[ "${STEW_UPDATE_SKIP_TEAM_CHECK:-0}" == "1" ]]; then
    note "Team check skipped (STEW_UPDATE_SKIP_TEAM_CHECK)."
  else
    signed_team="$(codesign -dv "$source_app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$signed_team" == "not set" ]] && signed_team=""
    [[ "$signed_team" == "$team_id" ]] || fail "Stew.app is signed by team '${signed_team:-none}', not Koode ($team_id). Not installing it."
    spctl --assess --type execute "$source_app" 2> /dev/null || fail "Gatekeeper does not accept this Stew.app (not notarized?). Not installing it."
    note "Signed by Koode ($team_id) and notarized."
  fi
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
