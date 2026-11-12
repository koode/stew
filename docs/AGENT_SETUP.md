# Setting up stew: instructions for a coding agent

You are setting up stew for the user on their Mac. stew is a floating panel that lets Claude Code sessions ask the user for permission, ask questions, send notifications and say when they need the user to do something only the user can do (log in, buy, approve in a web page), without taking keyboard focus. Follow these steps in order. Ask the user where a step says so; do not decide for them.

## 1. Check the machine

Run each check. Stop and tell the user if one fails, with the fix shown.

| Check | Command | Needs | Fix |
|---|---|---|---|
| macOS version | `sw_vers -productVersion` | 14 or later | Update macOS |
| Claude Code | `claude --version` | Installed | Needed only for the risk check and the auto mode hooks |
| Login type | `claude auth status` | `"authMethod": "claude.ai"` | The risk check runs only on a Claude subscription, never on API billing; it is skipped otherwise |

## 2. Ask the user two questions

1. **Hooks.** "Should stew ask you when Claude Code's auto mode blocks a call, and, when you are not at the terminal (background and remote sessions), show Claude's questions in stew and tell you when a session waits for you to do something (its reply ends with a `needs input:` line)? This adds hooks to `~/.claude/settings.json` (a backup is written first)."
2. **Keys and time.** "stew uses ⌘↩ to approve, ⌘D to deny, ⌘1 to ⌘4 for options and ⌘. to dismiss, while a panel is visible. You get 1 minute to answer before Claude is told you did not respond; ⌘E adds 2 minutes. Do you want different keys or times?"

## 3. Install

```bash
curl -fsSL https://releases.stewcli.com/install.sh | bash                    # if the user said no to hooks
curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks # if the user said yes
```

The script downloads the latest release, checks its SHA-256 and its Koode Developer ID signature, installs `~/Applications/Stew.app`, links `~/.local/bin/stew` to the tool inside it, starts the daemon as the LaunchAgent `nl.koode.stew`, and installs the Claude Code skill in `~/.claude/skills/stew`. An older install with a plain binary at `~/.local/bin/stew` is replaced in place. stew then updates itself once a day.

If the user works from a clone of this repository and wants to build from source, run `./install.sh` (or `./install.sh --with-hooks`) from its folder instead. That needs Swift 6 or later (`swift --version`; fix with `xcode-select --install` or an Xcode update).

If `~/.local/bin` is not on the user's PATH, the script says so. Add it to their shell profile only if they agree.

## 4. Change keys or times, if the user asked

The user can do this themselves in the settings window: `stew settings`. To do it for them, write `~/.config/stew/config.json` with only the fields that change. Example for Control+Option instead of Command, and 2 minutes to answer:

```json
{ "chord": "ctrl+option", "keys": { "approve": "y", "deny": "n", "dismiss": "w" }, "responseTimeout": 120 }
```

A bare key joins `chord`; a full spec such as `"cmd+shift+y"` stands alone. Keys without Control, Option or Command are refused. Run `stew keys` to show the result; it reports conflicts.

## 5. Verify

1. `stew version` prints a version and build number, and `stew keys` prints the shortcuts with no config error.
2. `launchctl print gui/$(id -u)/nl.koode.stew | grep state` shows `state = running`.
3. Send a test notification and ask the user to confirm they see it in the top right corner:
   ```bash
   stew notify "stew works" --body "Close this with ⌘. or ⌘↩"
   ```
4. If hooks were installed: `stew hooks status` shows `hooks: installed`.
5. Ask the user to answer one permission request, to confirm the keys work for them:
   ```bash
   stew permit --action "Test stew" --command "echo hello" --reason "Checking the setup" --timeout 120
   ```
   The output must show `"status":"approved"` after they press ⌘↩.
6. Show one needs item and ask the user to mark it done:
   ```bash
   stew needs "Check the stew setup" --step "Copy the command below with its copy button" --command "stew version" --wait --timeout 300
   ```
   The output must show `"status":"done"` after they press ⌘↩. While it is open, a hand with the count shows in the menu bar.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The panel says a key is "taken by another app" | Another app registered the same global shortcut | Remap that action in `~/.config/stew/config.json` |
| `daemon did not start` | The LaunchAgent is not loaded | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/nl.koode.stew.plist`, then read `~/Library/Logs/stew.log` |
| The install script stops with a sha256 or signature error | The download was damaged or is not an official build | Run the install command again. If it keeps failing, stop and tell the user; do not work around the check |
| "Risk check unavailable: not logged in with a Claude subscription" | `claude` uses an API key or is logged out | `claude auth login` with a Claude account, or set `"classifier": {"enabled": false}` |
| A blocked call never shows in stew | Hooks not installed, or the denial had no verdict | `stew hooks status`; denials such as "Classifier unavailable" cannot be retried, so stew skips them |
| `stew hooks status` says "partly installed" | The hooks come from an older stew, without the needs hooks | `stew hooks install` adds what is missing and keeps the rest |
| A `needs input:` line never shows in stew | The session is attended (someone at the terminal), or `autoNeeds` is `never` | Expected for attended sessions; set `"autoNeeds": "always"` in `~/.config/stew/config.json` if the user wants them too |

## Removing stew

```bash
stew uninstall
```

It removes the hooks, the daemon, Stew.app, the `~/.local/bin/stew` link, the skill, caches and stored approvals. It keeps `~/.config/stew` and any allow rules stew added to a project's `.claude/settings.local.json`; list those with `stew approvals` before uninstalling if the user wants them gone.
