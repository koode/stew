#!/usr/bin/env bash
# Builds Stew.app from source and installs it for the current user.
#
#   ./install.sh                 Stew.app, background daemon, Claude Code skill
#   ./install.sh --with-hooks    also ask in stew when Claude Code's auto mode blocks a call
#   ./install.sh --no-skill      skip the Claude Code skill
#   ./install.sh --bin-dir DIR   put the stew link somewhere other than ~/.local/bin
#   ./install.sh --app-dir DIR   put Stew.app somewhere other than ~/Applications
#
# Installs ~/Applications/Stew.app and links ~/.local/bin/stew to the tool inside it.
# An older install with a plain binary at ~/.local/bin/stew is replaced in place.
# Run it again to update. ./uninstall.sh removes everything.
set -euo pipefail
cd "$(dirname "$0")"

passthrough=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-hooks|--no-skill) passthrough+=("$1") ;;
    --bin-dir|--app-dir) passthrough+=("$1" "$2"); shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

echo "Building (release)…"
swift build -c release 2>&1 | grep -E 'error|warning: |Compiling|Build complete' | grep -v '^\[' || true
[[ -x .build/release/stew ]] || fail "build failed; run 'swift build -c release' to see why"

scripts/build-app.sh --binary .build/release/stew --out .build/app > /dev/null
# Ad-hoc signed, so the bundle and its Info.plist carry one consistent signature.
codesign --force --sign - --identifier nl.koode.stew .build/app/Stew.app 2> /dev/null

exec scripts/install-release.sh --app .build/app/Stew.app ${passthrough[@]+"${passthrough[@]}"}
