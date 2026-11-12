#!/usr/bin/env bash
# Builds stew from source and installs it for the current user.
#
#   ./install.sh                 binary, background daemon, Claude Code skill
#   ./install.sh --with-hooks    also ask in stew when Claude Code's auto mode blocks a call
#   ./install.sh --no-skill      skip the Claude Code skill
#   ./install.sh --bin-dir DIR   install the binary somewhere other than ~/.local/bin
#
# Run it again to update. ./uninstall.sh removes everything.
set -euo pipefail
cd "$(dirname "$0")"

with_hooks=0
with_skill=1
bin_dir="$HOME/.local/bin"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hooks) with_hooks=1 ;;
    --no-skill) with_skill=0 ;;
    --bin-dir) bin_dir="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

fail() { echo "stew: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "stew runs on macOS only"
macos_major=$(sw_vers -productVersion | cut -d. -f1)
[[ "$macos_major" -ge 14 ]] || fail "stew needs macOS 14 or later (this is $(sw_vers -productVersion))"
command -v swift > /dev/null || fail "no Swift toolchain. Install Xcode, or run: xcode-select --install"
swift_major=$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\).*/\1/p' | head -1)
[[ "${swift_major:-0}" -ge 6 ]] || fail "stew needs Swift 6 or later (found ${swift_major:-none}). Update Xcode or the Command Line Tools"

label="nl.koode.stew"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

echo "Building (release)…"
swift build -c release 2>&1 | grep -E 'error|warning: |Compiling|Build complete' | grep -v '^\[' || true
[[ -x .build/release/stew ]] || fail "build failed; run 'swift build -c release' to see why"

mkdir -p "$bin_dir" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
# Stop the running daemon before its binary is replaced.
launchctl bootout "$domain/$label" 2> /dev/null || true
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
echo "Installed $bin_dir/stew and started the daemon (LaunchAgent $label)."

if [[ $with_skill -eq 1 ]]; then
  mkdir -p "$HOME/.claude/skills/stew"
  install -m 644 skill/SKILL.md "$HOME/.claude/skills/stew/SKILL.md"
  echo "Installed the Claude Code skill in ~/.claude/skills/stew."
fi

if [[ $with_hooks -eq 1 ]]; then
  "$bin_dir/stew" hooks install
fi

command -v claude > /dev/null || echo "Note: the claude CLI is not on PATH. The risk check and the auto mode hooks need it."
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Note: $bin_dir is not on PATH. Add it to your shell profile, or call stew by its full path." ;;
esac

echo
"$bin_dir/stew" keys
echo
echo "Try it: $bin_dir/stew notify \"stew works\" --body \"Close this with ⌘. or ⌘↩\""
