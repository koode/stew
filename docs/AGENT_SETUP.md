# Setting up stew: instructions for a coding agent

You are setting up stew for the user on their Mac. These steps work the same whether you are Claude Code or Codex. stew is a floating panel that lets Claude Code and Codex sessions ask the user for permission, ask questions, ask for a typed answer (a domain, a code, a password), send notifications and say when they need the user to do something only the user can do (log in, buy, approve in a web page), without taking keyboard focus. Follow these steps in order. Ask the user where a step says so; do not decide for them.

## 1. Check the machine

Run each check. Stop and tell the user if one fails, with the fix shown.

| Check | Command | Needs | Fix |
|---|---|---|---|
| macOS version | `sw_vers -productVersion` | 14 or later | Update macOS |
| Claude Code | `claude --version` | Installed | Needed only for its skill and auto mode hooks, and for the risk check |
| Login type | `claude auth status` | `"authMethod": "claude.ai"` | The risk check runs only on a Claude subscription, never on API billing; it is skipped otherwise |
| Codex | `codex --version` | 0.122 or later | Needed only for its skill and approval hooks; older versions have no `PermissionRequest` hook |

Note which agents are installed (`~/.claude` and `~/.codex` exist): the questions and the install command below depend on it.

The user can also do all of this without you: stew opens a setup window when it first starts with no hooks installed, and it is in stew's menu bar menu as Set up stew…. It installs the skill and hooks per agent, shows a sample request and the keys, and points to the iPhone settings. If the user prefers that, install stew (step 3, without the hook commands) and tell them the window will guide them.

## 2. Ask the user two questions

1. **Hooks.** Ask only about the agents that are installed.
   - Claude Code: "Should stew ask you when Claude Code's auto mode blocks a call, and, when you are not at the terminal (background and remote sessions), show Claude's questions in stew and tell you when a session waits for you to do something (its reply ends with a `needs input:` line)? This adds hooks to `~/.claude/settings.json` (a backup is written first)."
   - Codex: "Should stew ask you first when Codex is about to ask for approval (a command outside the sandbox, a file edit, an MCP tool)? If you do not answer in time, Codex asks in the terminal as usual. This adds hooks to `~/.codex/hooks.json` (a backup is written first), and you then trust them once in Codex's `/hooks`."
2. **Keys and time.** "stew uses ⌘↩ to approve, ⌘D to deny, ⌘1 to ⌘4 for options and ⌘. to dismiss, while a panel is visible. You get 1 minute to answer before the agent is told you did not respond (for a Codex approval, Codex then asks in the terminal); ⌘E adds 2 minutes. Do you want different keys or times?"

## 3. Install

If `brew --version` works, use Homebrew:

```bash
brew trust --cask koode/apps/stew     # Homebrew loads casks from other taps only once trusted
brew install --cask koode/apps/stew
stew hooks install                 # only if the user said yes to Claude Code hooks
stew hooks install --agent codex   # only if the user said yes to Codex hooks
```

The cask installs `/Applications/Stew.app`, links the `stew` command and its shell completion, and runs `stew setup`, which starts the daemon as the LaunchAgent `nl.koode.stew` and installs the skill: in `~/.claude/skills/stew` if `~/.claude` exists, and in `~/.agents/skills/stew` (where Codex reads user skills) if `~/.codex` exists. It never adds the hooks itself. stew then updates itself once a day; `brew upgrade` leaves it alone unless `--greedy` is passed.

Without Homebrew, use the install script:

```bash
curl -fsSL https://releases.stewcli.com/install.sh | bash                    # if the user said no to hooks
curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks # Claude Code hooks
curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks --agent codex  # Codex hooks
curl -fsSL https://releases.stewcli.com/install.sh | bash -s -- --with-hooks --agent all    # both
```

The script downloads the latest release, checks its SHA-256 and its Koode Developer ID signature, installs `~/Applications/Stew.app`, links `~/.local/bin/stew` to the tool inside it, starts the daemon as the LaunchAgent `nl.koode.stew`, and installs the skill for each agent whose folder exists (`~/.claude/skills/stew`, `~/.agents/skills/stew`). An older install with a plain binary at `~/.local/bin/stew` is replaced in place. stew then updates itself once a day.

Do not use both. If stew is already installed with the script and the user wants Homebrew, `brew trust --cask koode/apps/stew && brew install --cask koode/apps/stew` takes over: it points `~/.local/bin/stew` at the new app and names the old `~/Applications/Stew.app`; ask the user before you delete that copy.

If the user works from a clone of this repository and wants to build from source, run `./install.sh` (or `./install.sh --with-hooks`, with `--agent codex` or `--agent all` for Codex) from its folder instead. That needs Swift 6 or later (`swift --version`; fix with `xcode-select --install` or an Xcode update).

If `~/.local/bin` is not on the user's PATH, the script says so. Add it to their shell profile only if they agree.

When stew starts with no hooks installed for any agent, it opens its setup window, without taking the keyboard. The install script with `--with-hooks` installs the hooks before stew starts, so the window stays closed; after `brew install` it opens before you run `stew hooks install`, and the user can close it or use it. Either way, tell the user where it is: Set up stew… in the menu bar menu.

If Codex hooks were installed, tell the user: "Open `/hooks` in Codex, review the stew hooks and trust them. Codex skips them until you do, and asks again if they change." You cannot do this step for them.

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
4. If hooks were installed: `stew hooks status --agent all` shows `hooks: installed` for Claude Code and `Codex hooks: installed` for Codex. It cannot see whether the user trusted the Codex hooks; ask them.
5. Ask the user to answer one permission request, to confirm the keys work for them:
   ```bash
   stew permit --action "Test stew" --command "echo hello" --reason "Checking the setup" --timeout 120
   ```
   The output must show `"status":"approved"` after they press ⌘↩.
6. Show one needs item and ask the user to mark it done:
   ```bash
   stew needs "Copy the stew version" --step "Copy the command below with its copy button" --command "stew version" --done "Copied it" --wait --timeout 300
   ```
   The output must show `"answer":"Copied it"` and `"status":"done"` after they press ⌘↩. While it is open, a hand with the count shows in the menu bar.
7. Ask the user to type one answer, to confirm the field works for them:
   ```bash
   stew input "Type stew to finish the setup" --pattern stew --timeout 120
   ```
   The field does not take the keyboard until they click it or press ⌘O. The output must show `"status":"answered"` and `"text":"stew"` after they type it and press ⌘↩.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| The panel says a key is "taken by another app" | Another app registered the same global shortcut | Remap that action in `~/.config/stew/config.json` |
| `daemon did not start` | The LaunchAgent is not loaded | `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/nl.koode.stew.plist`, then read `~/Library/Logs/stew.log` |
| The install script stops with a sha256 or signature error | The download was damaged or is not an official build | Run the install command again. If it keeps failing, stop and tell the user; do not work around the check |
| "Risk check unavailable: not logged in with a Claude subscription" | `claude` uses an API key or is logged out | `claude auth login` with a Claude account, or set `"classifier": {"enabled": false}` |
| A blocked call never shows in stew | Hooks not installed, or the denial had no verdict | `stew hooks status`; denials such as "Classifier unavailable" cannot be retried, so stew skips them |
| `stew hooks status` says "partly installed" | The hooks come from an older stew, without the needs hooks or the late answer hook | Tell the user to run `stew hooks install` (with `--agent codex` for Codex); it adds what is missing and keeps the rest. Do not edit `~/.claude/settings.json` or `~/.codex/hooks.json` yourself |
| A Codex approval never shows in stew | The hooks are not trusted yet, hooks are off in `~/.codex/config.toml`, or Codex is older than 0.122 | Ask the user to open `/hooks` in Codex and trust the stew hooks; `stew hooks status --agent codex` warns when `[features] hooks = false` |
| A `stew` command from Codex fails with a connection error | Codex's sandbox keeps it from reaching stew's socket | Expected in the sandbox: Codex asks to run it outside, and that approval shows in stew. A Codex rule that allows `stew` skips the prompt |
| An answer given late from the menu bar or History never reaches the agent | The session ended or was not in Claude Code or Codex, or the late answer hook is missing. A Codex approval that timed out is answered in Codex's own prompt, never late | `stew hooks status`; answers wait 24 hours for the session's next tool call, end of turn or message, then go |
| A `needs input:` line never shows in stew | The session is attended (someone at the terminal), it is a Codex session (Codex does not say whether anyone is watching), or `autoNeeds` is `never` | Expected for attended and Codex sessions; set `"autoNeeds": "always"` in `~/.config/stew/config.json` if the user wants them too |

## Removing stew

Installed with Homebrew:

```bash
brew uninstall --cask --zap stew
```

Installed with the script:

```bash
stew uninstall
```

`stew uninstall` refuses a Homebrew install and prints the brew command instead. It removes the hooks, the daemon, Stew.app, the `~/.local/bin/stew` link, the skill, caches and stored approvals. It keeps `~/.config/stew` and any allow rules stew added to a project's `.claude/settings.local.json`; list those with `stew approvals` before uninstalling if the user wants them gone.
