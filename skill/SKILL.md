---
name: stew
description: Reach the user on their desktop through a floating panel (the `stew` CLI) to ask permission for an action, ask a question in AskUserQuestion format, or tell them something. Use in background jobs and long-running work when the user is likely not watching the terminal, when blocked on a decision, when a long task finishes or fails, and whenever the user asks to be pinged, notified or asked.
---

# stew

`stew` shows a panel on the user's screen without taking keyboard focus, waits for the answer and prints it as one JSON line. The panel names this session automatically (the job name, or the folder).

The user answers with Command shortcuts (⌘↩ approve, ⌘D deny, ⌘1-⌘4 options), so plain typing in their terminal never answers by accident. They can always dismiss without answering.

## When to use it

- A background job needs a decision to continue. Ask with `stew ask` or `stew permit` before you stop to wait for the user.
- Long work finished, failed or needs attention: `stew notify`.
- The user asked to be notified, pinged or asked.

In a foreground session where the user is clearly typing to you, the normal AskUserQuestion tool is fine.

`stew permit` adds a human check; it does not replace or bypass Claude Code's own permission system. Never use it to get around a denied tool call.

## When auto mode blocks a call

If the user installed stew's hooks, a call that auto mode blocks goes to the user in stew. You see the normal denial first.

- If Claude Code then tells you that you may retry, the user approved it. Retry the identical call: same tool, same command, same description. Any change makes it a new call that auto mode reviews again.
- If the retry is denied with a note from the user, follow the note.
- If no retry message comes, the user denied or dismissed it. Find another way, or stop and say what you needed.

## Commands

```bash
# Permission. Exit 0 approved, 1 denied, 2 dismissed, 3 timeout.
stew permit \
  --action "Delete the stale build cache" \
  --command "rm -rf ~/Library/Caches/my-app-build" \
  --reason "The cache holds objects from an old toolchain and breaks the build."

# Long or multi-line command: pass it on stdin.
printf '%s' "$cmd" | stew permit --action "..." --command - --reason "..."

# Notification. Returns at once with "shown"; the panel stays until the user closes it.
stew notify "Tests passed" --body "212 of 212 green, the branch is ready to merge" --level success
#   --level info|success|warning|error, --wait blocks until acknowledged

# Question: exactly the AskUserQuestion input (1-4 questions, 2-4 options each).
stew ask --json '{"questions":[{"question":"Which database?","header":"DB","multiSelect":false,
  "options":[{"label":"Postgres","description":"Relational"},{"label":"SQLite","description":"Embedded"}]}]}'
# or: stew ask --file q.json, or JSON on stdin
```

Common flags: `--session NAME` overrides the label, `--timeout SECONDS` gives up with status `timeout`.

## Waiting

`permit` and `ask` block until the user answers, which can take a long time. Run them with the Bash tool's `run_in_background: true` and carry on with other work; you get notified when the command exits. For a short wait in the foreground, set the Bash `timeout` to 600000. If the Bash call is killed, the request disappears from the panel.

## Reading the answer

```json
{"status":"approved","note":"only the cache, not the logs","risk":{"verdict":"soft_deny","risk":"medium","rule":"...","summary":"..."}}
{"status":"denied","note":"use a migration instead"}
{"status":"answered","answers":{"Which database?":"SQLite"},"annotations":{...}}
{"status":"dismissed"}
```

- `note` is free text the user typed with their answer. Follow it; it can change what "approved" means.
- `answers` maps question text to the chosen label. Multi-select labels are joined with ", ". An "Other" answer is the user's own text.
- `dismissed` means the user closed it without answering. Do not repeat the same request. Stop or choose the safe path.
- `risk` is an automatic check of the command against the user's auto mode rules, shown to them above the command.

## Writing a good request

- `--action`: what you will do, in plain words, one line.
- `--command`: the exact command you will run, unchanged. Run exactly that after approval.
- `--reason`: why it is needed, in one or two sentences.
- Ask once per decision. Group related questions in one `stew ask` call.
