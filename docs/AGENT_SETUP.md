# Setting up stew: instructions for a coding agent

You are setting up stew for the user on their Mac. stew is a floating panel that lets Claude Code sessions ask the user for permission, ask questions and send notifications, without taking keyboard focus. Follow these steps in order. Ask the user where a step says so; do not decide for them.

## 1. Check the machine

Run each check. Stop and tell the user if one fails, with the fix shown.

| Check | Command | Needs | Fix |
|---|---|---|---|
| macOS version | `sw_vers -productVersion` | 14 or later | Update macOS |
| Swift toolchain | `swift --version` | Swift 6 or later | `xcode-select --install`, or update Xcode |
| Claude Code | `claude --version` | Installed | Needed only for the risk check and the auto mode hooks |
| Login type | `claude auth status` | `"authMethod": "claude.ai"` | The risk check runs only on a Claude subscription, never on API billing; it is skipped otherwise |

## 2. Ask the user two questions

1. **Auto mode hooks.** "Should stew ask you when Claude Code's auto mode blocks a call? This adds two hooks to `~/.claude/settings.json` (a backup is written first). A blocked call then waits up to 30 minutes for your answer in stew."
2. **Keys.** "stew uses ⌘↩ to approve, ⌘D to deny, ⌘1 to ⌘4 for options and ⌘. to dismiss, while a panel is visible. Do you want different keys?"

## 3. Install

From the repository folder:

```bash
./install.sh                 # if the user said no to hooks
./install.sh --with-hooks    # if the user said yes
```

The script builds a release binary, installs it to `~/.local/bin/stew`, starts the daemon as the LaunchAgent `nl.koode.stew`, and installs the Claude Code skill in `~/.claude/skills/stew`. Running it again updates everything.

If `~/.local/bin` is not on the user's PATH, the script says so. Add it to their shell profile only if they agree.

## 4. Change keys, if the user asked

Write `~/.config/stew/config.json` with only the fields that change. Example for Control+Option instead of Command:

```json
{ "chord": "ctrl+option", "keys": { "approve": "y", "deny": "n", "dismiss": "w" } }
```

A bare key joins `chord`; a full spec such as `"cmd+shift+y"` stands alone. Keys without Control, Option or Command are refused. Run `stew keys` to show the result; it reports conflicts.

## 5. Verify

1. `stew keys` prints the shortcuts with no config error.
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

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The panel says a key is "taken by another app" | Another app registered the same global shortcut | Remap that action in `~/.config/stew/config.json` |
| `daemon did not start` | The LaunchAgent is not loaded | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/nl.koode.stew.plist`, then read `~/Library/Logs/stew.log` |
| "Risk check unavailable: not logged in with a Claude subscription" | `claude` uses an API key or is logged out | `claude auth login` with a Claude account, or set `"classifier": {"enabled": false}` |
| A blocked call never shows in stew | Hooks not installed, or the denial had no verdict | `stew hooks status`; denials such as "Classifier unavailable" cannot be retried, so stew skips them |

## Removing stew

```bash
./uninstall.sh
```

It removes the hooks, the daemon, the binary, the skill, caches and stored approvals. It keeps `~/.config/stew` and any allow rules stew added to a project's `.claude/settings.local.json`; list those with `stew approvals` before uninstalling if the user wants them gone.
