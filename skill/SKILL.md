---
name: stew
description: Reach the user on their desktop through a floating panel (the `stew` CLI) to ask permission for an action, ask a question in AskUserQuestion format, tell them something, or tell them you need them to do something only they can do (log in, buy, approve in a web page, a physical action). Use in background jobs and long-running work when the user is likely not watching the terminal, when blocked on a decision or on the user, when a long task finishes or fails, and whenever the user asks to be pinged, notified or asked.
---

# stew

`stew` shows a panel on the user's screen without taking keyboard focus, waits for the answer and prints it as one JSON line. The panel names this session automatically (the job name, or the folder).

The user answers with Command shortcuts (⌘↩ approve, ⌘D deny, ⌘1-⌘4 options), so plain typing in their terminal never answers by accident. They can always dismiss without answering.

## When to use it

- A decision blocks you: ask with the normal AskUserQuestion tool. With stew's hooks installed, it shows in stew whenever nobody is at the terminal (background and remote sessions), and the answer comes back as usual. Use `stew ask` only when AskUserQuestion is not available to you.
- You need permission for something outside your tools' own prompts: `stew permit`.
- Long work finished, failed or needs attention: `stew notify`.
- You are blocked on something only the user can do (log in, enter a password or a 2FA code, buy or top up credits, approve something in a web page, plug in a device): `stew needs`. See below.
- The user asked to be notified, pinged or asked.

If AskUserQuestion comes back denied with a note that the user did not answer in time, or closed the question, they are probably away: continue with a safe choice that does not need the answer, and say which choice you made.

`stew permit` adds a human check; it does not replace or bypass Claude Code's own permission system. Never use it to get around a denied tool call.

## When auto mode blocks a call

If the user installed stew's hooks, a call that auto mode blocks goes to the user in stew. You see the normal denial first.

- If Claude Code then tells you that you may retry, retry the identical call: same tool, same command, same description. Any change makes it a new call that auto mode reviews again. The retry message alone does not mean the user approved: the retry itself gives the answer.
  - The retry runs: the user approved it.
  - The retry is refused with a note: the user denied it with that note, or did not respond in time (the note says so). Follow the note; do not tell the user they approved.
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

Common flags: `--session NAME` overrides the label. `--timeout SECONDS` sets the time to answer (default from the user's settings, 1 minute; `0` means no limit). The user can add time.

## When you need the user to do something

Use `stew needs` when you cannot go on until the user does something you cannot do for them. Never use it for a decision (ask instead) or for permission (`stew permit`).

```bash
stew needs "Log in to npm so I can publish 2.4.0" \
  --why "The publish failed with E401: this machine has no npm login." \
  --step "Run the command below in a terminal" \
  --step "Finish the login in the browser window it opens" \
  --command "npm login --auth-type=web" \
  --link https://www.npmjs.com/settings/tokens
# {"id":"3f9a1c2e","status":"shown"}
```

- The title says what you need, in one line. `--why` says what failed.
- `--step` (repeat it) gives the steps in order, in plain words. `--command` (repeat it) gives each command the user must run exactly as it must be run: the panel has a copy button, and it masks secrets on screen. `--link` takes only http or https URLs.
- It returns at once with an id, and stays open (also across restarts) until it is resolved. It has no time limit.
- Keep the id. Carry on with work that does not need it. When you can see the thing got done (the login works, the credits show, the build is approved), run `stew needs resolve ID`.
- To wait for the user instead: `--wait` (with the Bash tool's `run_in_background: true`). It returns `"done"` with the user's note, or `"dismissed"` if they declined. `--timeout SECONDS` limits only how long you wait: on `"timeout"` the item stays open.
- `stew needs list --json` shows what is open.

Also end your reply with the usual `needs input:` line saying what you need, on a line of its own. With stew's hooks installed, that line becomes a needs item by itself in background and remote sessions (a numbered list after it becomes the steps, code blocks in the message become commands, and web addresses outside them become links), and it goes away when the user next writes to you or when a later reply of yours has no `needs input:` line. When you already called `stew needs`, the line adds no second item.

## Waiting

`permit` and `ask` block until the user answers or the time to answer runs out (1 minute by default, but the user can extend it). Run them with the Bash tool's `run_in_background: true` and carry on with other work; you get notified when the command exits. For a short wait in the foreground, set the Bash `timeout` to 600000. If the Bash call is killed, the request disappears from the panel.

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
- `timeout` means the user did not answer in time (1 minute by default) and may be away. Read the `note`, continue another way that does not need this, and ask again later only if there is no other way.
- `risk` is an automatic check of the command against the user's auto mode rules, shown to them above the command.

## Writing a good request

- `--action`: what you will do, in plain words, one line.
- `--command`: the exact command you will run, unchanged. Run exactly that after approval.
- `--reason`: why it is needed, in one or two sentences.
- Ask once per decision. Group related questions in one `stew ask` call.
