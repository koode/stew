#!/usr/bin/env bash
# Tests the installers against a temporary home folder. launchctl calls are logged
# instead of run (STEW_INSTALL_LAUNCHCTL_LOG), so the real daemon is never touched,
# and Claude Code settings go to a temporary file.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEW="${STEW:-$ROOT/.build/debug/stew}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/stew-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
LAUNCHCTL_LOG="$WORK/launchctl.log"
mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/Library/LaunchAgents" "$FAKE_HOME/.claude"

failures=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; failures=$((failures + 1)); }
expect() { # name, haystack, needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected '$3' in: $2"; fi
}
in_home() {
  env HOME="$FAKE_HOME" STEW_INSTALL_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    STEW_CLAUDE_USER_SETTINGS="$WORK/claude-settings.json" STEW_CONFIG="$WORK/config.json" \
    STEW_SOCKET="$WORK/no-daemon.sock" "$@"
}

"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/build" --version 0.1.0 --build 3 > /dev/null
codesign --force --sign - --identifier nl.koode.stew "$WORK/build/Stew.app" 2> /dev/null

# The layout before Stew.app: a plain binary in ~/.local/bin and a LaunchAgent that runs it.
cp "$STEW" "$FAKE_HOME/.local/bin/stew"
cat > "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>nl.koode.stew</string>
<key>ProgramArguments</key><array><string>$FAKE_HOME/.local/bin/stew</string><string>daemon</string></array></dict></plist>
PLIST

out=$(in_home "$ROOT/scripts/install-release.sh" --app "$WORK/build/Stew.app" --with-hooks 2>&1); code=$?
expect "install exits 0" "$code" "0"
expect "install reports the version" "$out" "Installed stew 0.1.0 (build 3)"
expect "old binary is replaced" "$out" "Replacing the old binary"
app="$FAKE_HOME/Applications/Stew.app"
[[ -x "$app/Contents/MacOS/stew" ]] && pass "app installed" || fail "app installed" "no $app"
expect "stew is a link into the app" "$(readlink "$FAKE_HOME/.local/bin/stew")" "$app/Contents/MacOS/stew"
expect "LaunchAgent runs the app binary" "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist")" "$app/Contents/MacOS/stew"
expect "daemon stopped, then started" "$(tr '\n' ' ' < "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u)/nl.koode.stew launchctl bootstrap gui/$(id -u) $FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist"
[[ -f "$FAKE_HOME/.claude/skills/stew/SKILL.md" ]] && pass "skill installed" || fail "skill installed" "no SKILL.md"
expect "hooks installed" "$(cat "$WORK/claude-settings.json" 2>/dev/null)" "stew hook denied"
expect "the link runs the app" "$("$FAKE_HOME/.local/bin/stew" version)" "stew 0.1.0 (build 3)"
[[ ! -e "$FAKE_HOME/Applications/.Stew.app.installing" && ! -e "$FAKE_HOME/Applications/.Stew.app.previous" ]] \
  && pass "no staging left behind" || fail "no staging left behind" "$(ls -a "$FAKE_HOME/Applications")"

# Running it again updates in place.
"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/build" --version 0.1.1 --build 4 > /dev/null
codesign --force --sign - --identifier nl.koode.stew "$WORK/build/Stew.app" 2> /dev/null
out=$(in_home "$ROOT/scripts/install-release.sh" --app "$WORK/build/Stew.app" --no-skill 2>&1); code=$?
expect "update exits 0" "$code" "0"
expect "update replaces the app" "$("$FAKE_HOME/.local/bin/stew" version)" "stew 0.1.1 (build 4)"
[[ "$out" != *"Replacing the old binary"* ]] && pass "an existing link is kept as a link" || fail "an existing link is kept as a link" "$out"

out=$(in_home "$ROOT/scripts/install-release.sh" --bogus 2>&1); code=$?
expect "unknown option exits 64" "$code" "64"

# The uninstaller inside the app hands over to `stew uninstall`, which removes
# everything but the settings.
mkdir -p "$FAKE_HOME/.config/stew" "$FAKE_HOME/Library/Application Support/stew" "$FAKE_HOME/Library/Caches/stew"
echo '{}' > "$FAKE_HOME/.config/stew/config.json"
out=$(in_home "$app/Contents/Resources/uninstall.sh" 2>&1); code=$?
expect "uninstall exits 0" "$code" "0"
expect "uninstall.sh runs stew uninstall" "$out" "removed $app"
expect "hooks go before the daemon" "$(printf '%s' "$out" | head -1)" "removed stew hooks"
expect "LaunchAgent stopped" "$(tail -1 "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u)/nl.koode.stew"
[[ -f "$FAKE_HOME/.config/stew/config.json" ]] && pass "settings are kept" || fail "settings are kept" "config.json is gone"
[[ ! -e "$FAKE_HOME/Library/Application Support/stew" && ! -e "$FAKE_HOME/Library/Caches/stew" ]] \
  && pass "support and cache folders removed" || fail "support and cache folders removed" "$(ls "$FAKE_HOME/Library")"
[[ ! -e "$app" && ! -L "$FAKE_HOME/.local/bin/stew" && ! -e "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" && ! -e "$FAKE_HOME/.claude/skills/stew" ]] \
  && pass "uninstall removes app, link, LaunchAgent and skill" || fail "uninstall removes app, link, LaunchAgent and skill" "$(find "$FAKE_HOME" -name '*stew*' -o -name 'Stew.app')"
expect "uninstall removes the hooks" "$(cat "$WORK/claude-settings.json")" "{"
[[ "$(cat "$WORK/claude-settings.json")" != *"stew hook"* ]] && pass "no stew hooks left" || fail "no stew hooks left" "$(cat "$WORK/claude-settings.json")"

# The curl installer: latest.json and the zip from a local server.
SITE="$WORK/site"
mkdir -p "$SITE/v0.2.0"
"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/release" --version 0.2.0 --build 6 > /dev/null
codesign --force --sign - --identifier nl.koode.stew "$WORK/release/Stew.app" 2> /dev/null
ditto -c -k --keepParent "$WORK/release/Stew.app" "$SITE/v0.2.0/Stew-0.2.0.zip"
PORT=$(python3 -c 'import socket;probe=socket.socket();probe.bind(("127.0.0.1",0));print(probe.getsockname()[1]);probe.close()')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SITE" > "$WORK/http.log" 2>&1 &
HTTP=$!
trap 'kill $HTTP 2>/dev/null; wait $HTTP 2>/dev/null; rm -rf "$WORK"' EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break; sleep 0.1; done
publish() { # sha256 minimumMacOS
  cat > "$SITE/latest.json" <<JSON
{"version":"0.2.0","build":6,"published":"2026-11-20T10:00:00Z","minimumMacOS":"$2","notes":"https://stewcli.com/changelog#0.2.0",
 "archive":{"url":"http://127.0.0.1:$PORT/v0.2.0/Stew-0.2.0.zip","sha256":"$1","size":$(stat -f%z "$SITE/v0.2.0/Stew-0.2.0.zip"),"ed25519":"unused"}}
JSON
}
GOOD_SHA=$(shasum -a 256 "$SITE/v0.2.0/Stew-0.2.0.zip" | cut -d' ' -f1)
remote_install() { in_home env STEW_UPDATE_URL="http://127.0.0.1:$PORT/latest.json" "$@" "$ROOT/scripts/install-release.sh" --no-skill 2>&1; }

publish "$(printf '0%.0s' $(seq 1 64))" 14.0
out=$(remote_install STEW_UPDATE_SKIP_TEAM_CHECK=1); code=$?
expect "sha mismatch stops the install" "$out$code" "sha256 is $GOOD_SHA, expected"
[[ ! -e "$app" ]] && pass "nothing installed after a sha mismatch" || fail "nothing installed after a sha mismatch" "$app exists"

publish "$GOOD_SHA" 99.0
out=$(remote_install STEW_UPDATE_SKIP_TEAM_CHECK=1); code=$?
expect "too new for this macOS" "$out" "needs macOS 99.0 or later"

publish "$GOOD_SHA" 14.0
out=$(remote_install STEW_UPDATE_SKIP_TEAM_CHECK=0); code=$?
expect "ad hoc build fails the team check" "$out" "signed by team 'none', not Koode (PXD36584ME)"
[[ ! -e "$app" ]] && pass "nothing installed without the team" || fail "nothing installed without the team" "$app exists"

out=$(remote_install STEW_UPDATE_SKIP_TEAM_CHECK=1); code=$?
expect "download install exits 0" "$code" "0"
expect "download install verifies the zip" "$out" "Size and sha256 match."
expect "downloaded version installed" "$("$FAKE_HOME/.local/bin/stew" version)" "stew 0.2.0 (build 6)"

out=$(in_home "$FAKE_HOME/.local/bin/stew" uninstall); code=$?
expect "stew uninstall exits 0" "$code" "0"
[[ ! -e "$app" && ! -L "$FAKE_HOME/.local/bin/stew" ]] && pass "stew uninstall removes the app and link" || fail "stew uninstall removes the app and link" "$out"

echo
if [[ $failures -eq 0 ]]; then echo "all install checks passed"; else echo "$failures install check(s) failed"; fi
exit $failures
