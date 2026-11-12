# stew

A macOS panel that lets Claude Code sessions ask for permission, ask a question or send a notification, without taking keyboard focus from what you are typing.

- **Permission**: what Claude will do, the exact command, and why. A risk check against your auto mode rules shows above the command.
- **Question**: the same input as the AskUserQuestion tool, with options, multi-select, previews and an "Other" field.
- **Notification**: a title, an optional body and a level.

Every panel names the session it comes from and can always be dismissed.

## Keys

Nothing answers on plain keys, Space or Return, so text you are typing into a terminal never confirms anything. Every action is **⌘ (Command)** plus one key. The hotkeys exist only while a panel is visible, and they ignore presses for the first 0.5 s after a panel appears (`armDelay`), so a shortcut meant for another app cannot answer it.

| Keys | Action |
|---|---|
| ⌘↩ | Approve, or OK on a notification |
| ⌘D | Deny |
| ⌘O | Open the note or "Other" field (this is the only thing that takes focus) |
| ⌘1 to ⌘4 | Pick an option |
| ⌘↩ | Confirm a multi-select question or send typed text |
| ⌘[ / ⌘] | Previous or next question |
| ⌘. | Dismiss without answering |
| ⇧⌘. | Dismiss everything waiting |

When the risk check says auto mode would **never** allow a command (hard deny), Approve needs ⇧⌘↩, so a reflex press cannot approve it.

The keys avoid ones you press while typing: deny is ⌘D (the macOS "Don't Save" key) and not ⌘⌫, dismiss is ⌘. (the macOS cancel key) and not ⌘W, and question paging is ⌘[ / ⌘] and not ⌘← / ⌘→. While a panel is visible these keys go to stew, so Ghostty's ⌘D split and ⌘1 to ⌘4 tab switching wait until it closes.

The keys are looked up in your active keyboard layout, so "D" is the key that types D, also on Dvorak, Colemak or a remapped keyboard. On a split keyboard such as an ErgoDox, hold ⌘ on a thumb key and press the other key with either hand.

## Configuration

`~/.config/stew/config.json`. Every field is optional; changes apply to the next request without a restart. `stew keys` shows the keys in effect.

```json
{
  "chord": "cmd",
  "keys": { "approve": "return", "deny": "d", "dismiss": ".", "dismissAll": "cmd+shift+.",
            "other": "o", "submit": "return", "next": "]", "previous": "[" },
  "optionKeys": ["1", "2", "3", "4"],
  "hardDenyExtra": "shift",
  "armDelay": 0.5,
  "sound": "Glass",
  "position": "top-right",
  "classifier": { "enabled": true, "model": "haiku", "timeoutSeconds": 60, "recentUserMessages": 6 }
}
```

A bare key (`"d"`) joins the chord. A full spec (`"ctrl+option+y"`) stands alone. Approve and submit may share a key because they never show on the same panel; other clashes are refused. Keys without control, option or command are refused. `position` is `top-right`, `top-center` or `top-left`.

## Risk check

For each permission request the daemon runs `claude -p` with:

- the policy from `claude auto-mode config`, so your own allow and deny rules apply (cached per project for 10 minutes),
- the action, command, reason and folder,
- your last few messages from the session transcript, because auto mode weighs what you asked for.

The call has no tools and no settings sources (so no hooks), and it saves no session. It runs on your Claude subscription and counts toward your plan, never on API billing: API key variables are removed from its environment, and the check refuses to run unless `claude auth status` reports a claude.ai login. With Haiku a check takes approximately 4 to 6 seconds. The panel shows at once and the verdict appears when it is ready. The real auto mode classifier prompt is internal to Claude Code; this is an approximation that uses the same rules.

Run the check on its own:

```bash
stew check --action "Force-push main" --command "git push --force origin main" --reason "cleaner history"
```

## Install

```bash
./install.sh     # builds, installs ~/.local/bin/stew, LaunchAgent nl.koode.stew, Claude skill
./uninstall.sh   # removes all of it, keeps ~/.config/stew
```

Logs: `~/Library/Logs/stew.log`.

## Develop

```bash
swift test                     # unit tests (StewCore)
Tests/e2e/run.sh               # end-to-end against a headless daemon on a private socket
RISK_CHECK=1 Tests/e2e/run.sh  # also runs one real risk check
swift run stew snapshot --out snapshots   # renders sample panels to PNG, light and dark
```

The headless test daemon (`STEW_HEADLESS=1`) shows nothing and accepts simulated key presses on its socket. The real daemon refuses them, so a caller cannot approve its own request.
