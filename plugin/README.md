# stew for Claude Code

This plugin connects Claude Code to [stew](https://stewcli.com), a macOS panel that shows permission requests, questions and notifications without taking keyboard focus from what you are typing.

It needs the stew Mac app, which installs the `stew` command the plugin's hooks call. Install the app first:

```bash
brew trust --cask koode/apps/stew && brew install --cask koode/apps/stew
```

Without Homebrew: `curl -fsSL https://releases.stewcli.com/install.sh | bash`. See the [main README](https://github.com/koode/stew#install) for other options.

Then install the plugin, in Claude Code:

```
/plugin install stew --marketplace koode/stew
```

On Claude Code before 2.1.275, add the marketplace first: `/plugin marketplace add koode/stew`, then `/plugin install stew@stew`.

## What it adds

- **The stew skill**, which tells Claude when to ask, notify or hand you something to do through stew.
- **Hooks**, the same ones `stew hooks install` writes to `~/.claude/settings.json`:
  - `PermissionDenied`: when auto mode blocks a call, stew asks you. Approve, and Claude retries that exact call.
  - `PreToolUse`: lets an approved retry through once, and hands Claude answers you gave after a request timed out.
  - `PreToolUse` on AskUserQuestion: asks Claude's questions in stew in unattended sessions.
  - `Stop` and `UserPromptSubmit`: turn a `needs input:` line into a Needs you item, and clear it when you reply.

## Notes

- If the `stew` command is not installed, the hooks do nothing and Claude Code works as before.
- If you also ran `stew hooks install`, those hooks in `settings.json` run and the plugin's hooks step aside, so nothing runs twice. `stew hooks uninstall` removes them and leaves the plugin's hooks to do the work.
- Questions, Needs you and the time to answer are set in stew's own settings (`stew settings`).

## License

[Elastic License 2.0](https://github.com/koode/stew/blob/main/LICENSE).
