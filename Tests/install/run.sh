#!/usr/bin/env bash
# Tests the installers against a temporary home folder. launchctl calls are logged
# instead of run (STEW_INSTALL_LAUNCHCTL_LOG), so the real daemon is never touched,
# and Claude Code settings go to a temporary file. STEW_ZSH_FPATH stands in for the
# fpath of the user's zsh, so shell completion lands in the temporary folder too.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STEW="${STEW:-$ROOT/.build/debug/stew}"
# stew names its app by its own canonical path, so the work folder gets no doubled
# slash from a TMPDIR that ends in one.
TMP_ROOT="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${TMP_ROOT%/}/stew-install-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
FAKE_HOME="$WORK/home"
LAUNCHCTL_LOG="$WORK/launchctl.log"
SITE_FUNCTIONS="$WORK/share/zsh/site-functions"
mkdir -p "$FAKE_HOME/.local/bin" "$FAKE_HOME/Library/LaunchAgents" "$FAKE_HOME/.claude" "$FAKE_HOME/.config/fish" "$SITE_FUNCTIONS"

failures=0
pass() { echo "ok    $1"; }
fail() { echo "FAIL  $1"; echo "      $2"; failures=$((failures + 1)); }
expect() { # name, haystack, needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "expected '$3' in: $2"; fi
}
ZSH_FPATH="$SITE_FUNCTIONS:/usr/share/zsh/site-functions"
in_home() {
  env -u XDG_CONFIG_HOME -u ZDOTDIR HOME="$FAKE_HOME" STEW_INSTALL_LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    STEW_CLAUDE_USER_SETTINGS="$WORK/claude-settings.json" STEW_CONFIG="$WORK/config.json" \
    STEW_SOCKET="$WORK/no-daemon.sock" STEW_ZSH_FPATH="$ZSH_FPATH" PATH="$FAKE_HOME/.local/bin:$PATH" "$@"
}
FISH_COMPLETION="$FAKE_HOME/.config/fish/completions/stew.fish"
ZSH_COMPLETION="$SITE_FUNCTIONS/_stew"
FALLBACK_COMPLETION="$FAKE_HOME/.zsh/completions/_stew"


"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/build" --version 0.1.0 --build 3 > /dev/null
codesign --force --sign - --identifier nl.koode.stew "$WORK/build/Stew.app" 2> /dev/null

# install.sh marks its app as built from source, so the updater never installs over it;
# a release build carries no mark.
"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/source-build" --version 0.1.0 --build 3 --source-build > /dev/null
expect "source build is marked" "$(/usr/libexec/PlistBuddy -c 'Print :StewSourceBuild' "$WORK/source-build/Stew.app/Contents/Info.plist" 2>&1)" "true"
expect "release build is not marked" "$(/usr/libexec/PlistBuddy -c 'Print :StewSourceBuild' "$WORK/build/Stew.app/Contents/Info.plist" 2>&1)" "Does Not Exist"

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
expect "needs hooks installed" "$(python3 -c 'import json,sys;hooks=json.load(open(sys.argv[1]))["hooks"];print(hooks["Stop"][0]["hooks"][0]["command"].split(" hook ")[1], hooks["UserPromptSubmit"][0]["hooks"][0]["command"].split(" hook ")[1])' "$WORK/claude-settings.json" 2>&1)" "stop prompt"
expect "the link runs the app" "$("$FAKE_HOME/.local/bin/stew" version)" "stew 0.1.0 (build 3)"
[[ ! -e "$FAKE_HOME/Applications/.Stew.app.installing" && ! -e "$FAKE_HOME/Applications/.Stew.app.previous" ]] \
  && pass "no staging left behind" || fail "no staging left behind" "$(ls -a "$FAKE_HOME/Applications")"

# Shell completion: fish's own folder, and a writable site-functions folder on fpath.
expect "fish completion installed" "$out" "fish: wrote $FISH_COMPLETION"
expect "zsh completion installed on fpath" "$out" "zsh: wrote $ZSH_COMPLETION; new shells load it"
expect "fish completion is the binary's script" "$(cat "$FISH_COMPLETION" 2>&1)" "$(in_home "$FAKE_HOME/.local/bin/stew" completions fish)"
expect "zsh completion is the binary's script" "$(cat "$ZSH_COMPLETION" 2>&1)" "$(in_home "$FAKE_HOME/.local/bin/stew" completions zsh)"
[[ "$(cat "$WORK/completion-files" 2>&1)" == "$FISH_COMPLETION"$'\n'"$ZSH_COMPLETION" ]] \
  && pass "installed completion files are recorded" || fail "installed completion files are recorded" "$(cat "$WORK/completion-files" 2>&1)"
[[ -f "$app/Contents/Resources/completions/_stew" && -f "$app/Contents/Resources/completions/stew.fish" ]] \
  && pass "the app carries completion scripts for package managers" || fail "the app carries completion scripts for package managers" "$(ls "$app/Contents/Resources")"

# The installed scripts work in real shells. One open needs item, for `needs resolve`.
cat > "$WORK/needs.json" <<'JSON'
[{"id":"ab12cd34","created":"2026-11-13T10:00:00Z","session":{"name":"demo"},"needs":{"title":"Log in to npm","steps":[],"commands":[],"links":[],"answers":[]},"parked":false,"reminded":false}]
JSON
if command -v fish > /dev/null; then
  fish_complete() { in_home fish --no-config -c "source '$FISH_COMPLETION'; complete -C '$1'" 2>&1 | cut -f1 | tr '\n' ' '; }
  in_home fish --no-config -n "$FISH_COMPLETION" && pass "fish parses the script" || fail "fish parses the script" "fish -n failed"
  expect "fish completes commands" "$(fish_complete 'stew ne')" "needs"
  expect "fish completes subcommands" "$(fish_complete 'stew hooks ')" "install"
  expect "fish completes options" "$(fish_complete 'stew needs --')" "--answer"
  expect "fish completes option values" "$(fish_complete 'stew notify --level ')" "warning"
  expect "fish completes needs ids" "$(fish_complete 'stew needs resolve ')" "ab12cd34"
  [[ "$(fish_complete 'stew ')" != *"daemon"* && "$(fish_complete 'stew _')" != *"_control"* ]] \
    && pass "fish hides internal commands" || fail "fish hides internal commands" "$(fish_complete 'stew ')"
else
  echo "skip  fish checks: fish is not installed"
fi
zsh_complete() { in_home /bin/zsh -f "$ROOT/Tests/install/zsh-complete.zsh" "$SITE_FUNCTIONS" "$1" 2>&1 | tr '\n' ' '; }
/bin/zsh -n "$ZSH_COMPLETION" && pass "zsh parses the script" || fail "zsh parses the script" "zsh -n failed"
expect "zsh completes commands" "$(zsh_complete 'stew ne')" "needs"
expect "zsh completes subcommands" "$(zsh_complete 'stew needs ')" "list resolve"
expect "zsh completes options" "$(zsh_complete 'stew needs --w')" "--wait --why"
expect "zsh completes option values" "$(zsh_complete 'stew notify --level ')" "info success warning error"
expect "zsh completes needs ids" "$(zsh_complete 'stew needs resolve ')" "ab12cd34"
[[ "$(zsh_complete 'stew ')" != *"daemon"* ]] && pass "zsh hides internal commands" || fail "zsh hides internal commands" "$(zsh_complete 'stew ')"
bash -n <(in_home "$FAKE_HOME/.local/bin/stew" completions bash) && pass "bash parses the script" || fail "bash parses the script" "bash -n failed"

# Running it again updates in place. This time nothing on fpath is writable, so the
# zsh script goes to ~/.zsh/completions with a hint, and the earlier one is removed.
"$ROOT/scripts/build-app.sh" --binary "$STEW" --out "$WORK/build" --version 0.1.1 --build 4 > /dev/null
codesign --force --sign - --identifier nl.koode.stew "$WORK/build/Stew.app" 2> /dev/null
ZSH_FPATH="/usr/share/zsh/site-functions"
out=$(in_home "$ROOT/scripts/install-release.sh" --app "$WORK/build/Stew.app" --no-skill 2>&1); code=$?
expect "update exits 0" "$code" "0"
expect "update replaces the app" "$("$FAKE_HOME/.local/bin/stew" version)" "stew 0.1.1 (build 4)"
[[ "$out" != *"Replacing the old binary"* ]] && pass "an existing link is kept as a link" || fail "an existing link is kept as a link" "$out"
expect "zsh falls back to a personal folder" "$out" "zsh: wrote $FALLBACK_COMPLETION. To load it, add this line to ~/.zshrc above compinit:"
expect "the fallback prints the fpath line" "$out" "fpath=(~/.zsh/completions \$fpath)"
[[ -f "$FALLBACK_COMPLETION" && ! -e "$ZSH_COMPLETION" && -f "$FISH_COMPLETION" ]] \
  && pass "the zsh script moved, fish stayed" || fail "the zsh script moved, fish stayed" "$(ls "$SITE_FUNCTIONS" "$FAKE_HOME/.zsh/completions" 2>&1)"

out=$(in_home "$ROOT/scripts/install-release.sh" --app "$WORK/build/Stew.app" --no-skill --no-completions 2>&1); code=$?
expect "install without completions exits 0" "$code" "0"
[[ "$out" != *"shell completion"* ]] && pass "--no-completions skips shell completion" || fail "--no-completions skips shell completion" "$out"

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
expect "uninstall reports the completion files" "$out" "removed $FALLBACK_COMPLETION"
[[ ! -e "$FISH_COMPLETION" && ! -e "$FALLBACK_COMPLETION" && ! -e "$WORK/completion-files" && -d "$FAKE_HOME/.config/fish/completions" ]] \
  && pass "uninstall removes exactly the completion files" || fail "uninstall removes exactly the completion files" "$(find "$FAKE_HOME/.config" "$FAKE_HOME/.zsh" "$WORK/completion-files" 2>&1)"
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

[[ -f "$FISH_COMPLETION" && -f "$FALLBACK_COMPLETION" ]] && pass "download install adds shell completion" || fail "download install adds shell completion" "$out"
# A file of the same name that stew did not write stays, even when it is listed.
echo "#compdef stew" > "$SITE_FUNCTIONS/_stew"
echo "$SITE_FUNCTIONS/_stew" >> "$WORK/completion-files"

out=$(in_home "$FAKE_HOME/.local/bin/stew" uninstall); code=$?
expect "stew uninstall exits 0" "$code" "0"
[[ ! -e "$app" && ! -L "$FAKE_HOME/.local/bin/stew" ]] && pass "stew uninstall removes the app and link" || fail "stew uninstall removes the app and link" "$out"
[[ ! -e "$FISH_COMPLETION" && ! -e "$FALLBACK_COMPLETION" ]] && pass "stew uninstall removes the completion files" || fail "stew uninstall removes the completion files" "$out"
expect "a foreign _stew is left alone" "$(cat "$SITE_FUNCTIONS/_stew" 2>&1)" "#compdef stew"
rm -f "$SITE_FUNCTIONS/_stew"

# stew setup, the way the Homebrew cask runs it: the app is already in /Applications
# (here a temporary folder), the cask linked bin/stew in its prefix (HOMEBREW_PREFIX
# points at a temporary one with Caskroom/stew), and the postflight runs `stew setup`.
APPS="$WORK/Applications"
BREW="$WORK/homebrew"
mkdir -p "$APPS" "$BREW/bin" "$BREW/Caskroom/stew/0.2.0" "$WORK/no-homebrew"
ditto "$WORK/release/Stew.app" "$APPS/Stew.app"
cask_app="$APPS/Stew.app"
cask_tool="$cask_app/Contents/MacOS/stew"
ln -s "$cask_tool" "$BREW/bin/stew"
as_cask() { in_home env HOMEBREW_PREFIX="$BREW" "$@"; }
not_cask() { in_home env HOMEBREW_PREFIX="$WORK/no-homebrew" "$@"; }
plist_program() { /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" 2>&1; }

# Shell completion an earlier install from the script wrote; Homebrew links its own.
not_cask "$cask_tool" completions install > /dev/null
[[ -f "$FISH_COMPLETION" && -f "$FALLBACK_COMPLETION" ]] && pass "completion files from an earlier install" || fail "completion files from an earlier install" "$(cat "$WORK/completion-files" 2>&1)"
settings_before="$(cat "$WORK/claude-settings.json")"
: > "$LAUNCHCTL_LOG"

out=$(as_cask "$cask_tool" setup 2>&1); code=$?
expect "cask setup exits 0" "$code" "0"
expect "cask setup knows Homebrew installed the app" "$out" "(installed by Homebrew)"
expect "cask setup reports the version" "$out" "stew 0.2.0 (build 6) is set up."
expect "LaunchAgent runs the app where it is" "$(plist_program)" "$cask_tool"
expect "LaunchAgent restarts the daemon" "$(tr '\n' ' ' < "$LAUNCHCTL_LOG")" "launchctl bootout gui/$(id -u)/nl.koode.stew launchctl bootstrap gui/$(id -u) $FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist"
expect "LaunchAgent logs to the stew log" "$(/usr/libexec/PlistBuddy -c 'Print :StandardErrorPath' "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" 2>&1)" "$FAKE_HOME/Library/Logs/stew.log"
[[ -f "$FAKE_HOME/.claude/skills/stew/SKILL.md" ]] && pass "cask setup installs the skill" || fail "cask setup installs the skill" "$out"
[[ ! -e "$FAKE_HOME/.local/bin/stew" && ! -L "$FAKE_HOME/.local/bin/stew" ]] && pass "cask setup adds no stew link" || fail "cask setup adds no stew link" "$(ls -l "$FAKE_HOME/.local/bin")"
expect "cask setup leaves completion to Homebrew" "$out" "Shell completion comes from Homebrew."
[[ ! -e "$FISH_COMPLETION" && ! -e "$FALLBACK_COMPLETION" && ! -e "$WORK/completion-files" ]] \
  && pass "cask setup removes the earlier completion files" || fail "cask setup removes the earlier completion files" "$out"
[[ "$(cat "$WORK/claude-settings.json")" == "$settings_before" ]] && pass "setup leaves Claude Code settings alone" || fail "setup leaves Claude Code settings alone" "$(cat "$WORK/claude-settings.json")"
[[ ! -e "$FAKE_HOME/Applications/Stew.app" ]] && pass "no second copy in ~/Applications" || fail "no second copy in ~/Applications" "$(ls "$FAKE_HOME/Applications")"

out=$(as_cask "$cask_tool" setup --no-skill 2>&1); code=$?
expect "setup runs again" "$code" "0"
expect "a second run keeps the LaunchAgent" "$(plist_program)" "$cask_tool"
[[ ! -e "$FAKE_HOME/.local/bin/stew" && ! -e "$FISH_COMPLETION" ]] && pass "a second run adds nothing" || fail "a second run adds nothing" "$out"

out=$(as_cask "$cask_tool" setup --with-hooks 2>&1); code=$?
expect "setup --with-hooks exits 0" "$code" "0"
expect "setup --with-hooks adds the hooks for the app's tool" "$(cat "$WORK/claude-settings.json")" "Contents/MacOS/stew hook denied"
as_cask "$cask_tool" hooks uninstall > /dev/null

# Moving from the script to the cask: the old link now leads to the cask's app, so the
# path the hooks call keeps working, and the old copy is pointed out.
ditto "$WORK/release/Stew.app" "$FAKE_HOME/Applications/Stew.app"
ln -s "$FAKE_HOME/Applications/Stew.app/Contents/MacOS/stew" "$FAKE_HOME/.local/bin/stew"
out=$(as_cask "$cask_tool" setup --no-skill 2>&1); code=$?
expect "setup after a script install exits 0" "$code" "0"
expect "the old link leads to the cask's app" "$(readlink "$FAKE_HOME/.local/bin/stew")" "$cask_tool"
expect "the old copy is pointed out" "$out" "is no longer used. Remove it with: rm -rf"
rm -rf "$FAKE_HOME/Applications/Stew.app" "$FAKE_HOME/.local/bin/stew"

out=$(as_cask "$cask_tool" uninstall 2>&1); code=$?
expect "stew uninstall refuses a Homebrew install" "$out$code" "brew uninstall --cask --zap stew1"
[[ -f "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" ]] && pass "the refusal changes nothing" || fail "the refusal changes nothing" "$out"
out=$(as_cask "$cask_tool" uninstall --keep-app --app-dir "$APPS" 2>&1); code=$?
expect "uninstall --keep-app exits 0" "$code" "0"
[[ -x "$cask_tool" && ! -e "$FAKE_HOME/Library/LaunchAgents/nl.koode.stew.plist" && ! -e "$FAKE_HOME/.claude/skills/stew" ]] \
  && pass "uninstall --keep-app keeps only the app" || fail "uninstall --keep-app keeps only the app" "$out"

# The same app without Homebrew: setup adds the link and shell completion, as the script does.
out=$(not_cask "$cask_tool" setup --no-skill 2>&1); code=$?
expect "setup without Homebrew exits 0" "$code" "0"
[[ "$out" != *"Homebrew"* ]] && pass "setup without Homebrew does not claim it" || fail "setup without Homebrew does not claim it" "$out"
expect "setup without Homebrew links the command" "$(readlink "$FAKE_HOME/.local/bin/stew")" "$cask_tool"
[[ -f "$FISH_COMPLETION" && -f "$FALLBACK_COMPLETION" ]] && pass "setup without Homebrew installs shell completion" || fail "setup without Homebrew installs shell completion" "$out"
out=$(not_cask "$cask_tool" setup --no-skill --no-completions --bin-dir "$WORK/other-bin" 2>&1); code=$?
expect "setup --bin-dir links there" "$(readlink "$WORK/other-bin/stew")" "$cask_tool"
[[ "$out" != *"shell completion"* ]] && pass "setup --no-completions skips shell completion" || fail "setup --no-completions skips shell completion" "$out"
not_cask "$cask_tool" uninstall --app-dir "$APPS" --keep-app > /dev/null

out=$(in_home "$STEW" setup 2>&1); code=$?
expect "setup needs Stew.app" "$out$code" "this stew is not inside Stew.app"
out=$(in_home "$cask_tool" setup extra 2>&1); code=$?
expect "setup takes no arguments" "$code" "64"
expect "setup --help" "$(in_home "$cask_tool" setup --help)" "stew setup [--with-hooks] [--no-skill]"

# The Homebrew cask for a release, as scripts/release.sh writes it for the tap.
CASK="$WORK/tap/Casks/stew.rb"
SAMPLE_SHA=$(printf 'ab%.0s' $(seq 1 32))
out=$("$ROOT/scripts/render-cask.sh" --version 1.2.3 --sha256 "$SAMPLE_SHA" --url https://releases.stewcli.com/v1.2.3/Stew-1.2.3.zip --out "$CASK" 2>&1); code=$?
expect "cask renders" "$code" "0"
cask="$(cat "$CASK" 2>&1)"
expect "cask names the version" "$cask" 'version "1.2.3"'
expect "cask names the sha256" "$cask" "sha256 \"$SAMPLE_SHA\""
expect "cask url follows the version" "$cask" 'url "https://releases.stewcli.com/v#{version}/Stew-#{version}.zip"'
expect "cask lets stew update itself" "$cask" "auto_updates true"
expect "cask links the command" "$cask" 'binary "#{appdir}/Stew.app/Contents/MacOS/stew"'
expect "cask links the zsh completion the app carries" "$cask" 'zsh_completion "#{appdir}/Stew.app/Contents/Resources/completions/_stew"'
expect "cask runs stew setup" "$cask" 'args:         ["setup"]'
expect "cask zap keeps the app for Homebrew to remove" "$cask" '"uninstall", "--keep-app"'
[[ "$cask" != *"@"[A-Z]*"@"* ]] && pass "cask has no placeholders left" || fail "cask has no placeholders left" "$cask"
for completion in _stew stew.fish stew; do
  [[ -f "$cask_app/Contents/Resources/completions/$completion" ]] || fail "the app carries $completion" "$(ls "$cask_app/Contents/Resources/completions")"
done
if command -v ruby > /dev/null; then
  ruby -c "$CASK" > /dev/null 2>&1 && pass "cask is valid Ruby" || fail "cask is valid Ruby" "$(ruby -c "$CASK" 2>&1)"
else
  echo "skip  cask Ruby syntax: ruby is not installed"
fi
out=$("$ROOT/scripts/render-cask.sh" --version 1.2.3 --sha256 "$SAMPLE_SHA" --url https://releases.stewcli.com/latest/Stew.zip --out "$CASK" 2>&1); code=$?
expect "cask url must name the version" "$out$code" "--url must contain the version 1.2.31"

echo
if [[ $failures -eq 0 ]]; then echo "all install checks passed"; else echo "$failures install check(s) failed"; fi
exit $failures
