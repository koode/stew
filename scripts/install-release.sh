#!/usr/bin/env bash
# Installs stew for the current user. No admin rights needed.
#
#   curl -fsSL https://releases.stewcli.com/install.sh | bash
#   curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks
#
# What it installs:
#   ~/Applications/Stew.app                       the daemon and the command line tool
#   ~/.local/bin/stew                             a link to the tool inside Stew.app
#   ~/Library/LaunchAgents/nl.koode.stew.plist    starts the daemon at login
#   ~/.claude/skills/stew                         the Claude Code skill, if ~/.claude exists
#   ~/.agents/skills/stew                         the Codex skill, if ~/.codex exists
#   shell completion for fish and zsh             see `stew completions install`
# Everything after the app comes from `stew setup`, run from the new app.
#
# Options:
#   --with-hooks     also ask in stew when Claude Code's auto mode blocks a call
#   --agent NAME     the agent --with-hooks is for: claude (default), codex or all
#   --no-skill       skip the agent skills
#   --no-completions skip shell completion
#   --bin-dir DIR    put the stew link in DIR instead of ~/.local/bin
#   --app-dir DIR    put Stew.app in DIR instead of ~/Applications
#   --app PATH       install this Stew.app instead of the latest release. ./install.sh
#                    uses it after a source build; the Developer ID check is skipped.
#
# The download is checked before anything changes: size and sha256 from latest.json,
# then the code signature, which must be Koode's Developer ID (team PXD36584ME) and
# notarized. Run it again to update. An older install with a plain binary at
# ~/.local/bin/stew is replaced in place. Agent hooks call ~/.local/bin/stew, so
# they keep working. To remove stew: stew uninstall
#
# For tests only: STEW_UPDATE_URL points at another latest.json,
# STEW_UPDATE_SKIP_TEAM_CHECK=1 accepts ad hoc signed builds,
# STEW_INSTALL_LAUNCHCTL_LOG makes launchctl calls go to that file instead of
# running, so a test never stops or starts the real daemon, and STEW_ZSH_FPATH
# stands in for the fpath of the user's zsh.
set -euo pipefail

manifest_url="${STEW_UPDATE_URL:-https://releases.stewcli.com/latest.json}"
team_id="PXD36584ME"
label="nl.koode.stew"

with_hooks=0
hook_agent=""
with_skill=1
with_completions=1
bin_dir="$HOME/.local/bin"
app_dir="$HOME/Applications"
local_app=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hooks) with_hooks=1 ;;
    --agent) hook_agent="$2"; shift ;;
    --no-skill) with_skill=0 ;;
    --no-completions) with_completions=0 ;;
    --bin-dir) bin_dir="$2"; shift ;;
    --app-dir) app_dir="$2"; shift ;;
    --app) local_app="$2"; shift ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

[[ "$(uname -s)" == "Darwin" ]] || fail "stew runs on macOS only."
macos_version="$(sw_vers -productVersion)"
[[ "${macos_version%%.*}" -ge 14 ]] || fail "stew needs macOS 14 or later. This Mac has $macos_version."

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
    || fail "stew $release_version needs macOS $minimum_macos or later. This Mac has $macos_version."

  step "Downloading stew $release_version"
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
tool="$app/Contents/MacOS/stew"
domain="gui/$(id -u)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_app/Contents/Info.plist")"

mkdir -p "$app_dir"

step "Stopping the running daemon"
launchctl_run bootout "$domain/$label" 2> /dev/null || true

step "Installing stew $version in $app_dir"
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

# The rest is the same for every install, so the new app does it itself: the stew
# link (replacing an old plain binary there, so the path that hooks call stays the
# same), the LaunchAgent, the skill, shell completion and the hooks.
setup_options=(--bin-dir "$bin_dir")
[[ $with_hooks -eq 1 ]] && setup_options+=(--with-hooks)
[[ -n "$hook_agent" ]] && setup_options+=(--agent "$hook_agent")
[[ $with_skill -eq 0 ]] && setup_options+=(--no-skill)
[[ $with_completions -eq 0 ]] && setup_options+=(--no-completions)
"$tool" setup "${setup_options[@]}" || fail "setup did not finish; see above. To try again: $tool setup ${setup_options[*]}"

echo
echo "Installed $("$tool" version)."
command -v claude > /dev/null || note "The claude command is not on PATH. The risk check and the auto mode hooks need it."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) note "$bin_dir is not on PATH. Add it to your shell profile, or call stew by its full path." ;;
esac
echo
"$tool" keys
echo
echo "Try it: stew notify \"stew works\" --body \"Close this with ⌘. or ⌘↩\""
