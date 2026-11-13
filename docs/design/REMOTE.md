# Remote machines: design

Status: proposal. Nothing in this document is built yet.

This document describes how a second machine can run `stew` so that its Claude Code requests show on the user's main Mac, and from there on their iPhone, with the answers going back to the machine that asked. The second machine can be another Mac, a headless Linux server or VM, a machine reached over SSH, or a cloud agent box.

The plan is to offer two transports. SSH forwarding is free. Pairing over the relay, like the iPhone, is a paid feature.

References to the current code use `path:line`. They point at the `stew-v1` branch at commit `e681b0f`.

## 1. Use cases and non-goals

### Use cases

| Case | What happens today | What this design adds |
|---|---|---|
| Interactive SSH session to a dev server, Claude Code runs there | `stew` is not installed or cannot reach a panel. Auto mode blocks end the call; questions stay in the terminal. | Blocked calls, questions and inputs show on the Mac panel. |
| Background agent on a server (`claude -p`, scheduled job, tmux session left running) | Nobody sees a blocked call or a `needs input:` line until someone logs in. | The request reaches the Mac, and the iPhone when the user is away. Late answers reach the session at its next hook. |
| CI-like job or cloud agent box (ephemeral VM, container) | No human channel at all. | `stew needs`, `stew notify` and permission requests reach the user. The job blocks on the answer with the same exit codes as on the Mac. |
| A second Mac | It runs its own daemon and panel. | Optional: send its requests to the main Mac instead, so one panel and one phone cover both. |

### Non-goals (for now)

- **Several users.** One person owns the Mac, every paired remote and every phone. Team routing ("ask whoever is on call") is out of scope.
- **Running a panel on Linux.** The remote has no UI. It asks and waits.
- **A remote answering anything.** A remote can only ask. It never approves, denies or answers a request, its own or anyone else's.
- **Windows.** Claude Code on Windows is not a target. WSL counts as Linux.
- **Remote control of the Mac daemon.** A remote cannot pause, stop, update or configure the Mac.

## 2. How the current system works (what this builds on)

- **The CLI talks to a local daemon over a Unix socket.** `Client.send` connects to `Paths.socket`, writes one JSON line and reads one line back (`Sources/stew/Client.swift:7-19`). The socket is `~/Library/Application Support/stew/stew.sock` with mode 0600 (`Sources/stew/Paths.swift:25-28`, `Sources/stew/Daemon.swift:90`). `STEW_SOCKET` already overrides the path, for tests (`Sources/stew/Paths.swift:25-27`).
- **If nothing listens, the CLI starts a daemon.** It kickstarts the LaunchAgent, or spawns `stew daemon` (`Sources/stew/Client.swift:59-83`). With `STEW_SOCKET` set it always spawns a local daemon (`Sources/stew/Client.swift:74-82`).
- **The daemon reads both requests and control lines on the same socket.** Controls include `stop`, `pause`, `resume`, `update`, `needs …` and `late secret …` (`Sources/stew/Coordinator.swift:201-245`). Simulated key presses exist only in the headless test daemon (`Sources/stew/Coordinator.swift:239-242`, `Sources/stew/Paths.swift:33-35`). Pairing over the socket is headless-only too (`Sources/stew/PhoneLink.swift:589-594`).
- **A request is a `StewRequest`**: session (name, id, cwd), prompt, timeout, maxWait, wait, origin (`Sources/StewCore/Models.swift:4-20`, `Sources/StewCore/Models.swift:167-189`). The session name comes from `--session`, `STEW_SESSION`, a background job's name or the folder name (`Sources/StewCore/SessionResolver.swift:12-18`). Nothing names the machine.
- **Exit codes** are 0 approved or answered, 1 denied, 2 dismissed, 3 timeout, 4 error, 5 later (`Sources/StewCore/Models.swift:334-343`, `README.md:163-173`).
- **When the caller goes away** (EOF on the socket), the daemon drops the request and records it without an answer (`Sources/stew/Daemon.swift:34-37`, `Sources/stew/Coordinator.swift:526-537`). Only a timeout or "later" makes a request answerable late (`Sources/stew/Coordinator.swift:599-603`).
- **Hooks run in short-lived `stew hook …` processes** on the machine where Claude Code runs. `PermissionDenied` asks and then writes the one-shot grant into `grants.json` itself (`Sources/stew/Hooks.swift:150-221`). Hard deny names come from `claude auto-mode config` in the project (`Sources/stew/Hooks.swift:167`, `Sources/stew/Hooks.swift:333-336`). `PreToolUse` returns at once when neither `grants.json` nor `late-answers.json` exists (`Sources/stew/Hooks.swift:86-102`). Hook timeouts are 1800 s for the waiting hooks and 5 to 15 s for the others (`Sources/StewCore/Grants.swift:435-441`).
- **Late answers** live in `late-answers.json` next to the socket. The daemon writes them; the hooks deliver them (`Sources/stew/LateAnswerFile.swift:5-49`). A late secret stays in the daemon's memory, and the hook fetches it with `late secret ID` (`Sources/stew/LateAnswerFile.swift:51-59`, `Sources/stew/Coordinator.swift:607-623`). A late approval writes the retry grant on the daemon's side (`Sources/stew/Coordinator.swift:676-690`).
- **The phone link** is end to end: X25519 plus HKDF salted with a 32 byte pairing secret, ChaCha20-Poly1305, Ed25519 signatures (`Sources/StewLink/LinkChannel.swift:66-111`, `docs/PHONE.md:114`). Pairing uses a code shown on the Mac and six digits typed on the Mac (`docs/PHONE.md:21-33`, `Sources/StewLink/Pairing.swift:71-80`). The relay is a Worker with one Durable Object per pairing (`relay/README.md:3`). It stores one Mac key and one phone slot per pairing (`relay/src/pairing.ts:120-129`), and accepts kinds per sender from a fixed table (`relay/src/pairing.ts:34-37`).
- **The phone sees every request in the panel queue.** `PhoneLink.tick` walks `coordinator.items` and pushes what the policy allows (`Sources/stew/PhoneLink.swift:506-545`). A request from any source that becomes an `Item` therefore reaches the phone with no extra work.
- **The code is source-available under the Elastic License 2.0** (`LICENSE`, `README.md:404-406`), and the relay can be self-hosted (`relay/README.md:103`).

## 3. Overview of the design

```
remote machine                           Mac                                  iPhone
--------------                           ---                                  ------
Claude Code
  └─ stew hook denied ─┐
  └─ stew ask/permit ──┤
                       ▼
             (a) SSH:  forwarded Unix socket ──► per-remote listener ─┐
             (b) relay: stew agent ──► relay DO (remote pairing) ──► ─┤
                                                                      ▼
                                                         Coordinator queue ──► panel
                                                                      └──────► PhoneLink ──► relay ──► phone
```

Both transports end in the same place: the request becomes an ordinary `Item` in the Mac's `Coordinator`, tagged with the machine it came from. The panel, History, the risk display and the iPhone push all work from that `Item`. Only three things are new on the Mac side: where the request came in, how the answer goes back, and which side-effects the Mac must not perform for a remote request.

## 4. Transport A (free): SSH remote socket forwarding

### How it works

OpenSSH can forward a Unix socket from the remote back to a Unix socket on the Mac:

```
ssh -R /home/me/.stew/mac.sock:/Users/me/.stew/remote/devbox.sock devbox
```

On the remote, `stew` connects to `/home/me/.stew/mac.sock`. The bytes arrive at the Mac's listener for `devbox`. The wire format is the same JSON line protocol as today (`Sources/stew/Client.swift:11-15`).

### What changes

| Area | Change | Why |
|---|---|---|
| Socket path on the remote | The remote CLI reads `remote.socket` from its config, then `STEW_SOCKET`, then the default `~/.stew/mac.sock`. | `Paths.socket` is a macOS path under `~/Library` (`Sources/stew/Paths.swift:13-28`). |
| No local daemon start | In remote mode the CLI never tries to start a daemon. When nothing listens it fails at once with `{"status":"error","error":"the Mac is not reachable at …"}` and exit 4. | Today a missing socket spawns `stew daemon` (`Sources/stew/Client.swift:59-83`), which cannot work on Linux and would hide a dead forward. |
| One listener per remote on the Mac | `stew remote add-ssh devbox` makes the Mac daemon listen on `~/.stew/remote/devbox.sock` in addition to `stew.sock`, and prints the `RemoteForward` line for `~/.ssh/config`. | The listener that received a request is the only thing the Mac can trust about where it came from. Bytes on a forwarded socket carry no peer identity: `getpeereid` returns the Mac user, because the Mac's own `ssh` process connects. |
| Short path without spaces | Listeners live in `~/.stew/remote/`, not under `Application Support`. | `sun_path` is 104 bytes on macOS (`Sources/stew/Client.swift:38-42`), and a path with a space is awkward in `ssh_config`. |
| Restricted control set on remote listeners | A remote listener accepts requests and four controls only: `needs resolve ID`, `needs answered SESSION`, `needs moved-on SESSION` and the new `late mail` and `late secret` controls, each limited to items that came in on that listener. Everything else (`stop`, `pause`, `update`, `settings`, `history` and the headless test controls) answers `not allowed from a remote`. | The main socket accepts every control (`Sources/stew/Coordinator.swift:201-245`). A remote must not stop, pause or update the Mac, or fetch a secret that belongs to a local session. |
| Session label | Each request gets `session.host` set by the Mac to the listener's name. A host name the remote sends is ignored for the label and kept only as a detail. | See section 7, "Labels". |
| Late answers over SSH | New control `late mail SESSION AGENT EVENT` (section 8). | The Mac writes late answers into its own `late-answers.json`, which the remote's hooks cannot read (`Sources/stew/LateAnswerFile.swift:10`). |

### Session naming

The remote sets `session.name` as today (`Sources/StewCore/SessionResolver.swift:12-18`). The Mac adds the machine name, so the panel header reads `devbox · api-server` (machine, then session). The cwd stays the remote's path, shown as is. The Mac's own requests show no machine name, so the common case does not change.

### Authentication and what SSH gives

- **Who can use the forwarded socket.** sshd creates it with `StreamLocalBindMask`, by default 0177, so mode 0600 and owned by the SSH user. Any process of that user, and root, on the remote can send requests. That is the same trust as "Claude Code runs as this user on this box".
- **No keys to manage.** SSH already authenticated both ends. There is no pairing and no relay.
- **What it does not give.** The Mac cannot tell which remote user or process asked; it only knows which listener. Two remotes that forward to the same listener look the same. Hence one listener per remote.
- **The phone still works.** A request from a remote is an ordinary `Item`, so `PhoneLink.tick` pushes it when the Mac is idle (`Sources/stew/PhoneLink.swift:525-543`).

### When SSH drops

| Moment | Today's behavior | Proposed behavior |
|---|---|---|
| Request waiting, connection drops | EOF closes the `Connection` (`Sources/stew/Daemon.swift:34-37`). The item is removed and recorded without an answer, so it cannot be answered late (`Sources/stew/Coordinator.swift:526-537`, `594-603`). The phone copy is resolved as dismissed (`Sources/stew/PhoneLink.swift:516-521`). | For a request from a remote listener that has a session id: record it as **Connection lost** and keep it answerable late, like a timeout. History lists it under Missed. |
| The CLI on the remote | `readLine` gets EOF and the CLI exits 4 with "daemon closed the connection without an answer" (`Sources/stew/Client.swift:12-14`). | Same exit 4, message "the connection to the Mac was lost". |
| Hooks on the remote | `denied` prints nothing, so auto mode's block stands (`Sources/stew/Hooks.swift:214-216`). `question` falls back to the terminal (`Sources/stew/Hooks.swift:139-141`). | Unchanged. The remote hook also writes a local "waiting" record so a late answer can be fetched later (section 8). |
| New request while SSH is down | The forwarded socket file may still exist; `connect` fails with `ECONNREFUSED` at once. | Exit 4 at once. No retry loop: a hook has a time limit and the terminal fallback is better than a hang. |
| Reconnect | The forward needs the old socket file gone. Without `StreamLocalBindUnlink yes` in the remote's `sshd_config`, the new forward fails with "remote port forwarding failed". | `stew remote add-ssh` prints the `sshd_config` line and explains it. `stew doctor` on the remote says "stale socket at …" when the file exists and nothing answers. |

Two SSH sessions to the same host with the same `RemoteForward` share one path. With `StreamLocalBindUnlink yes` the newest session owns it; when that session closes, the older session's forward is gone too. This is a known limit of a fixed path. Users who keep several sessions open use `ControlMaster`, which shares one forward.

## 5. Transport B (paid): pairing a remote over the relay

### Why

SSH forwarding works only while an SSH session is open. A background agent on a server, a scheduled job or a cloud box usually runs with no SSH session. Pairing over the relay gives such a machine its own end-to-end encrypted channel to the Mac, like the iPhone has.

### Pairing flow

It follows the phone's flow (`docs/PHONE.md:21-33`), with the roles that fit a headless box.

1. **On the Mac:** Settings ▸ Machines ▸ Pair a machine, or `stew remote pair` on the Mac. The Mac claims a new pairing id at the relay with `kind: "remote"` (section 6) and shows the code as text and as a QR code. The text is the same `stew://pair?code=…` form (`Sources/StewLink/Pairing.swift:33-38`) with one new field, `"t":"remote"`. The code works for 10 minutes and for one machine, like a phone code (`docs/PHONE.md:23`).
2. **On the remote:** `stew remote pair`. It asks for the code on the terminal with echo off, or reads it from stdin (`stew remote pair --code-stdin`), so the code never lands in shell history or `ps`. It makes the remote's key pair, registers with the relay and sends `hello` with its keys and its host name.
3. **The remote prints six digits.** The user types them on the Mac. The Mac never shows them (`docs/PHONE.md:25`), so they can only come from the machine that holds the code. The digits come from the same function as the phone's (`Sources/StewLink/Pairing.swift:71-80`), over the remote's signing key.
4. **On the Mac:** the user names the machine. The default is the host name from `hello`, cut to 40 characters. This name is the label on every request (section 7).

Each pairing has its own id, its own pairing secret and its own keys, as for phones (`docs/PHONE.md:33`). A remote can pair with several Macs. A Mac can pair with several remotes.

**Why the code comes from the Mac and not the remote:** the Mac claims the pairing id with its signing key before anything else exists (`relay/src/pairing.ts:240-269`). A remote that showed a code would need the Mac to trust a pairing it did not start. Keeping the phone's direction reuses the claim, the registration token and the "no self-approval" property: a process that took a copied code gets no further without the six digits typed on the Mac (`docs/PHONE.md:119`).

**Old iPhone apps** decode the code with `JSONDecoder`, which ignores the unknown `t` field, so an old app would try to pair with a remote code. The relay refuses: a `remote` pairing does not accept `POST /device` with an APNs token (`409 wrong_kind`). New phone apps refuse a `remote` code before they contact the relay.

### Ephemeral boxes

A cloud box that lives one hour cannot be paired by hand each time. Two options, both left to the owner (question 6):

- **Reuse one remote identity.** Pair once, then put the remote's key file into the job's secrets (`STEW_LINK_KEYS` as base64, or a mounted file). Every box that holds it is the same "machine" on the Mac. Revoking it revokes all of them.
- **Pre-approved invitations.** The Mac makes a code valid for N registrations and D days, and skips the six digits. This removes the human check that stops a copied code, so it should not be the default.

## 6. Protocol changes (relay transport)

### Pairing kind

The claim gets a `kind` field, `phone` (the default, so today's Macs keep working) or `remote`. It is part of the signed claim text:

```
stew-link/1 claim\n{id}\n{hash}\n{ts}\n{kind}
```

Today's claim text has no kind (`Sources/StewLink/Pairing.swift:94-96`). An old Mac sends the old text, and the relay treats it as `phone`. The relay stores the kind in the pairing row (`relay/src/pairing.ts:120-129`) and never changes it.

### Sides and directions

`LinkSide` gets a third value, `remote` (`Sources/StewLink/LinkEnvelope.swift:22-26`; `relay/src/envelope.ts:10`). The `sender` is in the signed header (`docs/PHONE.md:145`), so a message cannot change sides. The header format and `v: 1` stay as they are.

In a remote pairing, requests go the other way from a phone pairing:

| Sender | Kind | Payload (inside the ciphertext) | Relay action |
|---|---|---|---|
| remote | `hello` | host name, keys | As for a phone: store keys, queue for the Mac until acked (`relay/src/pairing.ts:318`). |
| remote | `request` | `RemoteRequest`: request id, the `StewRequest`, the remote's host name and stew version | Forward on the Mac's socket. 202, or 503 `mac_offline`. Not stored. |
| remote | `resolved` | request id, reason (`caller_gone`) | Forward on the Mac's socket, or drop if the Mac is offline. |
| remote | `unpair` | reason | As a phone's unpair (`relay/src/pairing.ts:420-428`). |
| mac | `answer` | the `StewResponse` for one request | Forward on the remote's socket, else keep in `remote_outbox` until acked or expired. |
| mac | `update` | request id, state (`queued`, `shown`, deadline) | Forward if the remote is online; drop otherwise. Lets `stew` print "waiting on the Mac" progress to stderr. Optional. |
| mac | `late` (new) | a `LateAnswer` plus its retry grant, and the secret when the input was secret | Like `answer`: socket or outbox. |
| mac | `unpair` | reason | Send, then delete the pairing. |

`kindsBySender` becomes a table per pairing kind (`relay/src/pairing.ts:34-37`). A phone pairing keeps today's table exactly. `late` is a new value in `KINDS` (`relay/src/envelope.ts:9`), which an old relay refuses with `unsupported_kind`. That is fine: remote pairings need the new relay anyway.

Controls that a remote may send (`needs resolve`, `needs answered`, `needs moved-on`) travel as `request` with a control payload, so the relay cannot tell a control from a question.

### The remote's socket

The remote agent (section 9) opens `GET /v1/pairings/{id}/socket?side=remote`, signed with the remote's key over `stew-link/1 socket\n{id}\n{ts}\nremote`. The Durable Object tags it `remote`, next to today's `mac` tag (`relay/src/pairing.ts:28`, `507-517`). It acks outbox frames with `{"type":"ack","messageId":…}` as the Mac does for hello and unpair (`docs/PHONE.md:165`).

WebSockets on Durable Objects can hibernate, so an idle remote costs little. A long-poll `GET /wait` stays as a fallback for clients without WebSocket support (risk R2 in section 12).

### Push

None. A remote has no APNs token. The relay never sends a push for a remote pairing. The iPhone still gets pushes for remote requests through the Mac's own phone pairings, because the request is a Mac `Item` by then.

### Replay and expiry

The existing rules stay: unique message id, expiry not past (60 s skew) and at most 7 days ahead, signature against the stored key, message id recorded at the relay until it expires (`Sources/StewLink/LinkChannel.swift:135-167`, `relay/README.md:18`). On top:

| Message | `expiresAt` | Extra check on receipt |
|---|---|---|
| remote `request` | now + `maxWait` + 60 s, at most 1840 s for hook requests (the hook's 1800 s limit, `Sources/stew/Hooks.swift:53-54`); now + 1 day for `needs` | The Mac refuses a request id it has seen in this run, and a `StewRequest` that fails validation (`Sources/stew/Coordinator.swift:190-198`). |
| mac `answer` | now + 10 minutes | The remote takes it only for a request id it is still waiting for. A second answer for the same id is ignored. |
| mac `late` | the late answer's own end: answered + 24 h (`Sources/StewCore/LateAnswers.swift:88`) | The remote's mailbox is keyed by history entry id (`Sources/StewCore/LateAnswers.swift:117-121`), so a replay after a restart of the agent adds nothing. |

The phone's 30 second rule for answers (`Sources/StewLink/LinkPresentation.swift:381`, `Sources/stew/PhoneLink.swift:269-271`) protects the Mac from a relay that holds an answer back. The remote needs no such rule for `answer`: the remote's caller is waiting and takes the first answer for its id, and a held-back answer only arrives after the caller timed out, when it is ignored.

### Rate limits

| Where | Limit | Reason |
|---|---|---|
| Relay, per address | Unchanged: 60 requests per 10 s (`relay/README.md:22`). | |
| Relay, per pairing, all posts | Unchanged bucket of 60, 1 per second (`relay/src/rate-limit.ts:8`). | |
| Relay, per remote pairing, `request` | New bucket of 20, 1 per 6 s, like the Mac's request bucket (`relay/src/rate-limit.ts:10-11`). | Each request can become a panel and a phone alert. |
| Mac, per remote | At most 3 open permission requests, questions and inputs, and 10 open needs items. More are refused at once with `"too many open requests from devbox"`, exit 4. | The relay limit is per pairing and coarse. The Mac is where flooding hurts. |
| Mac, per remote | Mute for 1 hour, from the panel's menu and from Settings ▸ Machines. A muted remote's requests time out at once, as while paused (`Sources/stew/Coordinator.swift:249-253`, `824-830`). | One noisy box must not drown the rest. |

The SSH transport gets the same Mac-side limits.

### What the relay stores in addition

- The pairing kind.
- The remote's public keys (in the columns the phone uses today, renamed `peer_*`).
- `remote_outbox`: `answer`, `late` and `unpair` envelopes for an offline remote, until acked or expired. A late secret sits here as ciphertext for at most 24 hours. This is the one place where a secret's ciphertext is stored at rest: the phone path never carries a secret (`docs/PHONE.md:16`). The relay cannot decrypt it, but it is a new property and the owner should decide on it (question 4).
- No device token, no pending or resolved requests.

What the relay learns as metadata: when a remote asks, how often, the padded size of each message (`Sources/StewLink/LinkChannel.swift:113-126`), and the remote's IP address while it is connected. Logs stay off for full URLs (`relay/README.md:101`).

## 7. On the Mac: requests from a remote

### Labels

| Surface | Today | With remotes |
|---|---|---|
| Panel header | Session name, cwd, session id in the tooltip (`Sources/stew/Views.swift:140-159`). | A machine chip before the session name: `devbox · api-server`. The tooltip adds "Asked from devbox (paired 2026-11-02, via relay)" or "(via SSH)". |
| History | Session and cwd per row (`Sources/StewCore/History.swift:151`). | A Machine column. The rule is one kind of value per column: no chip in front of the session name in a table. |
| iPhone | Title is the session name, subtitle has the cwd (`Sources/StewLink/LinkPresentation.swift:225-231`). | Title `devbox · api-server`. `LinkRequest` already carries `macName` (`Sources/StewLink/LinkPayloads.swift:19`); the machine goes into `session.host`, so the phone can show "devbox via MacBook". An old phone app ignores the field and shows the session name. |
| Menu bar list of needs items | Session · title. | Machine · session · title. |

The label is the name the user gave the pairing on the Mac, or the SSH listener's name. It is never the name the remote sends. A compromised remote can put any text into `session.name`, but it cannot change the chip.

`SessionInfo` gets an optional `host` field (`Sources/StewCore/Models.swift:4-13`). The Mac sets it when a request arrives from a remote and clears whatever the remote put there.

### Answers going back

Today an answer goes back through `item.connection`, which is a socket `Connection` (`Sources/stew/Coordinator.swift:539-555`, `Sources/stew/Daemon.swift:8-61`). That becomes a small `Responder` protocol with three implementations: the local socket, a remote listener socket (SSH), and a relay remote (sends an `answer` envelope). The Coordinator does not need to know which one it has.

### Side-effects the Mac must skip for a remote request

These are bugs waiting to happen, because the code today assumes the asker shares the Mac's file system.

| Code | What it does today | For a remote request |
|---|---|---|
| `Coordinator.storeLateAnswer` (`Sources/stew/Coordinator.swift:676-690`) | Writes the one-shot retry grant into the Mac's `grants.json`, and for "Always" writes `.claude/settings.local.json` under the request's project root, creating folders on the way (`Sources/stew/Hooks.swift:307-314`). | Must not write anything on the Mac. The grant goes to the remote inside the late answer (section 8). Without this, a remote path such as `/srv/app` would get created on the Mac. |
| History ▸ Allow next time… (`Sources/stew/HistoryWindow.swift:64-69`) | Writes a standing grant into the Mac's `grants.json` for that project. | Hidden for remote rows in phase 1. Phase 2 can send it to the remote as a `late`-like grant message. |
| Risk check for a direct `stew permit` (`Sources/stew/Coordinator.swift:266-278`) | Runs `claude -p` in the session's cwd and reads the session transcript from the Mac's `~/.claude/projects` (`Sources/stew/RiskChecker.swift:40`, `136-153`). | The cwd and the transcript do not exist on the Mac. Run the check with the Mac's rules and no transcript, and say so above the verdict: "Checked on this Mac, without the session's messages." A check on the remote could be forged by a compromised remote, so the Mac does not take a verdict from it. |
| Approvals window (`Sources/stew/ApprovalsWindow.swift:21-33`) | Lists the Mac's grants. | Unchanged. Remote grants are listed on the remote with `stew approvals --list` (section 10). |

### Hard denies from a remote

The `PermissionDenied` hook on the remote decides `hardDeny` from the remote's own auto mode rules (`Sources/stew/Hooks.swift:167`). The Mac cannot check that claim. It shows:

- the same red hard deny banner and the ⇧⌘↩ approve as for a local call (`Sources/stew/Views.swift:344-347`, `Sources/stew/Views.swift:443`), with the text "Auto mode on devbox never allows this";
- no standing approvals, as today (`README.md:113`);
- on the iPhone, Deny and More time only, as today (`docs/PHONE.md:11`).

A compromised remote could claim "soft deny" for something its rules call a hard deny. That only makes the approve key easier for a call that the same compromised remote could run without asking. It does not affect the Mac.

## 8. Late answers from a remote

The hooks run on the remote, so the late-answer mailbox must be readable there. The mailbox format stays `LateMailbox` (`Sources/StewCore/LateAnswers.swift:85-121`), and the hook code that reads it stays as it is (`Sources/stew/Hooks.swift:97`, `261`, `276`). What changes is who writes the remote's copy.

### The "waiting" record keeps `PreToolUse` fast

`PreToolUse` runs before every tool call and must return at once when there is nothing to do (`Sources/stew/Hooks.swift:84-92`). The remote knows when a late answer is possible: only after one of its own requests ended with `timeout`, `later` or connection lost, for a session with an id (`Sources/StewCore/LateAnswers.swift:108-114`). At that moment the remote CLI or hook adds a waiting record to its own `late-answers.json` (`addWaiting`, `Sources/StewCore/LateAnswers.swift:117-121`). While no waiting record exists for a session, hooks on the remote do no network or socket call at all.

### SSH

- New control on remote listeners: `late mail SESSION AGENT EVENT`. The Mac marks the matching answers delivered and returns them, each with its retry grant (tool name, call key, session id) and the grant choice for "Allow more…", if any.
- The remote hook writes the retry grant into the remote's `grants.json` with `GrantBook.approveLate` (`Sources/StewCore/Grants.swift:200-205`) and applies a standing choice with `Hooks.apply` on the remote (`Sources/stew/Hooks.swift:307-318`). Then it prints the answer as today.
- A late secret: the hook asks `late secret ID` on the same listener, as today (`Sources/stew/LateAnswerFile.swift:54-59`). The Mac hands it out only to the listener the request came from.
- The hook asks only while it has a waiting record for that session, and at most once per 15 s for `PreToolUse`. `Stop` and `UserPromptSubmit` always ask while a record exists. When SSH is down, the call fails at once and the record stays.

### Relay

- When the user answers late on the Mac or the phone, the Mac sends a `late` envelope to the remote. The relay forwards it, or keeps it in `remote_outbox` (section 6).
- The remote agent writes it into the remote's `late-answers.json` and the retry grant into `grants.json`, then acks. A late secret stays in the agent's memory and is handed out once over the agent's local socket with `late secret ID`, the same call the hook makes today (`Sources/stew/LateAnswerFile.swift:56`). The hooks do not change.
- If the agent is not running when a hook finds a waiting record, the hook starts it (section 9). The agent connects, drains the outbox and writes the mailbox. The hook does not wait for that: the answer arrives at the next hook call.

### Who can answer late

Today a phone can answer late only while the Mac runs (`docs/PHONE.md:9`). Nothing changes there: the Mac keeps the waiting request, and the phone or the Mac's History answers it. The remote only receives.

## 9. The remote client

### What runs on the remote

Two pieces, both in one `stew` binary for Linux (and for a Mac in remote mode):

| Piece | What it does | Lifetime |
|---|---|---|
| `stew` CLI and `stew hook …` | The same commands, flags, JSON output and exit codes as on the Mac (`README.md:160-194`). Talks to a local socket. | One call. |
| `stew agent` (relay transport only) | Listens on the remote's local socket with the same line protocol as the Mac daemon, so the CLI and the hooks do not change. Holds the remote's keys and the relay WebSocket. Forwards requests, waits for answers, writes late answers and grants, keeps late secrets in memory. | Started on demand by the CLI, like the Mac daemon (`Sources/stew/Client.swift:59-83`, `97-113`). Exits after 10 minutes with no open request and no waiting record. A systemd user unit is offered for boxes that want it always on. |

With SSH, the CLI talks straight to the forwarded socket and no agent runs.

Why an agent rather than a CLI that talks to the relay itself:

| | Agent on a local socket | CLI talks to the relay directly |
|---|---|---|
| Hook and CLI code | Unchanged: they still speak the local socket protocol. | Every command needs relay code, keys and signing. |
| Late answers | Pushed by the Mac, written by the agent when it runs. | Each hook with a waiting record must poll the relay, inside a 5 to 10 s hook limit (`Sources/StewCore/Grants.swift:437-441`). |
| Late secrets | In the agent's memory only, like the Mac daemon (`Sources/stew/Coordinator.swift:607-609`). | Must be fetched from the relay outbox by a hook. |
| Running process | One small process while there is something to wait for. | None. |
| Containers without an init | Works: started on demand, exits when idle. | Works. |

### Which code builds on Linux

| Module | Linux status | Work |
|---|---|---|
| `StewCore` | Imports only Foundation, except `Update.swift`, which uses CryptoKit for update signatures (`Sources/StewCore/Update.swift:1`, `200-209`). Uses `NSRegularExpression` and `NSString` path helpers (`Sources/StewCore/CommandText.swift:9-12`, `Sources/StewCore/Needs.swift:345-347`), which exist in swift-corelibs-foundation. | Import `Crypto` (swift-crypto) when CryptoKit is missing. Check date formatting on Linux. |
| `StewLink` | Uses CryptoKit for Curve25519, ChaChaPoly, HKDF and SHA256 (`Sources/StewLink/Pairing.swift:1`, `Sources/StewLink/LinkKeys.swift:1`, `Sources/StewLink/LinkChannel.swift:1`). | swift-crypto has the same API. `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif`, and a package dependency only for Linux (`.when(platforms: [.linux])`). |
| `stew` executable | Links AppKit, Carbon and AudioToolbox (`Package.swift:15-19`). `main.swift` and `Daemon.swift` import AppKit (`Sources/stew/main.swift:1`, `Sources/stew/Daemon.swift:1`). `Paths.executable` uses `_NSGetExecutablePath` (`Sources/stew/Paths.swift:43-50`). The client uses `Darwin.connect`, `read` and `write` (`Sources/stew/Client.swift:48`, `119`, `133`). | Split it: a new `StewCLI` library with command parsing, `Client`, `Hooks`, `GrantFile`, `LateAnswerFile`, `Paths` and `RiskChecker.policyJSON`; the macOS `stew` executable on top of it with the daemon and UI; a `stew` Linux product on top of it with `stew agent`. Use `Glibc` beside `Darwin`, `/proc/self/exe` for the executable path, `MSG_NOSIGNAL` instead of `SO_NOSIGPIPE` (`Sources/stew/Daemon.swift:100-101`). |
| Hooks | `projectRoot` runs `/usr/bin/git` (`Sources/stew/Hooks.swift:66-78`). `hardDenyNames` runs `claude auto-mode config` (`Sources/stew/Hooks.swift:333-336`). | Both work on Linux. `Paths.claudeBinary` needs no change: `~/.local/bin/claude` is its first guess (`Sources/stew/Paths.swift:61-68`). |
| Relay WebSocket | The Mac uses `URLSessionWebSocketTask` (`Sources/stew/RelayConnection.swift:42-67`). | `FoundationNetworking` on Linux has it, built on libcurl's WebSocket support. Its reliability is a risk (R2); the long-poll fallback covers it. |

The alternative is a separate small client (Go or Rust) for the remote. It would duplicate the envelope, the key derivation and the late-answer format in a second language, and the fixtures in `relay/test/fixtures/swift-envelopes.json` would have to cover two encoders. Recommendation: one Swift code base, with the split above.

### Paths on Linux

| File | macOS | Linux (remote) |
|---|---|---|
| Config | `~/.config/stew/config.json` (`Sources/stew/Paths.swift:31`) | Same, honoring `XDG_CONFIG_HOME` |
| Agent socket | `~/Library/Application Support/stew/stew.sock` | `$XDG_RUNTIME_DIR/stew/stew.sock`, else `~/.stew/stew.sock` |
| SSH forwarded socket | (n/a) | `~/.stew/mac.sock` |
| `grants.json`, `late-answers.json` | next to the socket (`Sources/stew/Hooks.swift:7-9`, `Sources/stew/LateAnswerFile.swift:10`) | `$XDG_STATE_HOME/stew/`, else `~/.local/state/stew/`, mode 0600, folder 0700. Not next to the socket, because `XDG_RUNTIME_DIR` is cleared at logout. |
| Remote keys and pairings | (Mac keeps its own in the login keychain, `Sources/stew/PhoneStore.swift:34-45`) | `~/.config/stew/link.json`, mode 0600, folder 0700 |
| Log | `~/Library/Logs/stew.log` (`Sources/stew/Paths.swift:37`) | `$XDG_STATE_HOME/stew/stew.log` |

### Keys on a headless box

- **Default:** a 0600 file, like the headless test daemon's `phone-link.json` (`Sources/stew/PhoneStore.swift:60-63`). The agent refuses to start when the file or its folder is readable by others, and says which `chmod` fixes it.
- **Optional keyring:** the Secret Service API (libsecret) when a session bus exists. Most servers have none, so this is opt-in with `remote.keyStore: "keyring"`.
- **Injected:** `STEW_LINK_KEYS` (base64 of the stored identity and pairing) for containers and CI secrets. Never written to disk by stew.
- **What a stolen key gives:** the power to ask the Mac, as that machine, until the user unpairs it. Not the power to answer anything.

### A request while it waits

The CLI blocks exactly as on the Mac: one JSON line on stdout, the same exit codes (`Sources/StewCore/Models.swift:334-343`). While it waits, it prints nothing on stdout. With `--progress`, it prints one stderr line per state change ("sent to MacBook", "on screen", "time extended to 14:32").

| Situation | Result |
|---|---|
| The Mac answers | The answer, exit 0, 1 or 2. |
| The time runs out on the Mac | `{"status":"timeout",…}`, exit 3, with the note from the Mac (`README.md:198`). The remote adds a waiting record. |
| The Mac is offline (relay 503 `mac_offline`) or the SSH socket is dead | Exit 4 at once with "the Mac is not reachable". Hooks fall back as today. For `needs` and `notify` without `--wait`, the agent keeps the item and sends it when the Mac comes back (at most 1 day), and the CLI returns `{"status":"shown"}` with `"queued":true`. |
| The connection drops while waiting | The agent waits up to 60 s for the relay to come back, then exits 4 with "the connection to the Mac was lost". The Mac treats it as connection lost (section 4). |
| `maxWait` passes with no answer (hook requests) | `{"status":"timeout"}` from the agent's own clock, exit 3, so the hook ends inside Claude Code's 1800 s limit (`Sources/stew/Hooks.swift:126`, `194`). |

## 10. Hooks on the remote

`stew hooks install` on the remote writes the same six hooks into the remote's `~/.claude/settings.json` (`Sources/stew/Hooks.swift:338-349`, `Sources/StewCore/Grants.swift:435-441`). Each one works as follows when the panel is elsewhere:

| Hook | What it does on the remote | Changes |
|---|---|---|
| `PermissionDenied` (`hook denied`) | Reads the blocked call, finds the project root and the hard deny rules on the remote, asks the Mac, and on approval writes the one-shot grant into the remote's `grants.json` (`Sources/stew/Hooks.swift:150-221`). A category grant for the project short-cuts the question, as today (`Sources/stew/Hooks.swift:157-165`). | None, beyond the transport. Grants stay on the remote, so the retry passes. |
| `PreToolUse` (`hook pre`) | Checks the remote's `grants.json` and late answers (`Sources/stew/Hooks.swift:86-102`). | Over SSH: asks `late mail` only while a waiting record exists (section 8). |
| `PreToolUse` on AskUserQuestion (`hook question`) | Routes the question when the session is unattended (`Sources/stew/Hooks.swift:108-146`). | None. An interactive SSH session is attended, so its questions stay in the terminal unless `routeQuestions` is `always` in the remote's config. |
| `Stop` (`hook stop`, background) | Turns a `needs input:` line into a needs item (`Sources/stew/Hooks.swift:228-252`). | The remote keeps a local list of the needs items it created per session, so `UserPromptSubmit` can tell whether to ask the Mac. Today that check reads the Mac's `needs.json` (`Sources/stew/Hooks.swift:286-292`), which the remote does not have. |
| `Stop` (`hook stop-late`, foreground) | Delivers late answers and keeps Claude going (`Sources/stew/Hooks.swift:258-266`). | Over SSH: `late mail` while a waiting record exists. |
| `UserPromptSubmit` (`hook prompt`) | Ends the session's automatic needs items and delivers late answers (`Sources/stew/Hooks.swift:272-281`). | Uses the local list above; sends `needs answered SESSION` to the Mac only for its own items. |

Grants live on the remote only. "Allow more…" on the Mac returns the choice in the answer (`response.grant`), and the remote hook applies it, so "Always" writes `.claude/settings.local.json` in the remote project (`Sources/stew/Hooks.swift:204-206`, `307-314`). New on the remote: `stew approvals --list` and `stew approvals revoke ID`, because the Approvals window on the Mac shows only the Mac's grants.

## 11. Security

### Threat model

| Actor | Can | Cannot |
|---|---|---|
| A compromised remote (root, or the user's account) | Ask the Mac anything, with any text in the session name, command and reason. Claim any hard deny or category. Use its rate and open-request budget. Read answers to its own requests, including secrets the user typed for it. | Answer or approve any request, its own or another's. Read requests from the Mac or from other remotes. Stop, pause, update or configure the Mac. Change the machine label. Write files on the Mac (section 7). Pair a new phone or remote. |
| The relay | See metadata (section 6). Drop or delay messages. Hold an `answer` back until the caller has timed out. | Read or forge a request, an answer or a late answer, as for phones (`docs/PHONE.md:116`). Swap keys during pairing without the six digits failing to match. |
| Another process on the Mac | Same as today: it can send requests to `stew.sock` (`README.md:367`). | Answer: the daemon still takes answers only from its own panel and from paired phones. |
| Someone who copies a pairing code | Register first, as with phones. | Get further: the real remote shows no digits, so there is nothing to type on the Mac (`docs/PHONE.md:119`). |

The rule that holds this together: **a remote can only ask.** The Mac never runs a command, never writes a file and never stores a grant because of a remote request. Every effect of an approval happens on the remote that asked.

### The Mac must show clearly which machine asks

- The machine chip is on every panel, in History and on the phone (section 7).
- The chip comes from the Mac's own record of the pairing or listener, never from request content.
- The first request from a newly paired machine shows a one-time line under the chip: "First request from devbox."
- Settings ▸ Machines lists each paired machine with its transport (SSH or relay), when it last asked, its open requests, Mute and Unpair.

### Unpairing and revocation

- **Relay:** Unpair on the Mac sends `unpair`, deletes the Mac's record, and the relay deletes the pairing (`relay/src/pairing.ts:411-414`, `649-666`). After that, the relay answers `unknown_pairing` to the remote and the Mac has no key to open its messages. A remote that ignores the unpair can do nothing. `stew remote unpair` on the remote sends `unpair` from that side.
- **SSH:** Remove the listener in Settings ▸ Machines, or `stew remote remove devbox`. The forwarded socket on the remote then gets connection refused.
- **Lost or stolen key file:** unpair from the Mac. There is no remote-side recovery to do.

### Flooding

Covered by the limits in section 6: relay bucket per pairing, at most 3 open asks and 10 open needs items per machine, Mute per machine, and the global pause. The arrival sound plays only when the queue was empty (`Sources/stew/Coordinator.swift:279-284`), so a burst makes one sound.

### Secrets typed for a remote

A secret typed on the Mac for a remote input goes to the remote: over the forwarded socket for SSH, inside the ciphertext for the relay. The Mac does not write it anywhere, as today (`README.md:152`). A late secret is held in the Mac's memory until the remote fetches it (SSH) or is sent once in a `late` envelope (relay). The relay outbox can hold that ciphertext up to 24 hours (question 4). The phone never receives a secret (`docs/PHONE.md:16`), for a remote request too.

## 12. Licensing and the paid boundary

### What is free and what is paid

| Part | Free or paid | Reason |
|---|---|---|
| Linux build of the CLI, hooks on the remote | Free | Needed by both transports. |
| SSH forwarding | Free | No cost to run; uses the user's own SSH. |
| Remote pairing on a self-hosted relay | Free | The code is source-available under the Elastic License 2.0 (`README.md:404-406`) and the relay is self-hostable (`relay/README.md:103`). A gate in client code can be removed by anyone who builds it. |
| Remote pairing on the hosted relay (`relay.stewcli.com`) | Paid | This is the service that costs money to run: Durable Object storage, sockets, the outbox. |

### Where to enforce

The honest place is the hosted relay, at claim time for `kind: "remote"`. The Mac also checks locally, but only to show the right state in Settings; the local check is not the gate.

No user credential of another service goes anywhere. The proof is a signed token that only says "this purchase exists".

| Option | How it works | For | Against |
|---|---|---|---|
| A. License token signed by Koode | After a purchase (for example a Stripe or Paddle checkout), the buyer gets a token: random license id, plan, max machines, expiry, Ed25519 signature. Paste it into Settings ▸ Machines. The Mac sends it with the remote claim. The relay checks the signature with an embedded public key, as the updater checks releases (`README.md:368`), and counts live remote pairings per license id. | Works without an iPhone. Offline check, no account. The same signing approach is already in the code base (`Sources/StewCore/Update.swift:200-209`). | Needs a checkout, an email for the token and a way to re-issue it. The relay can link the pairings of one license id. |
| B. In-app purchase in the iPhone app | StoreKit 2 gives a JWS transaction signed by Apple. The phone sends it to the Mac over the existing link; the Mac sends it with the remote claim; the relay checks Apple's certificate chain, bundle id and product id. | Apple handles payment, refunds and family sharing. No Koode checkout or customer data. | Requires an iPhone and a paired phone. Apple's 15 to 30 percent. A user without an iPhone cannot buy. Subscription status needs the relay to refresh the JWS from time to time. |
| C. Local license file only, checked by the Mac | A signed file in `~/.config/stew/license.json`, checked by the daemon. The relay does not check. | Simplest. No relay change. | Anyone who builds from source can patch it out, against the license. Only honest users pay. |
| D. Sponsorship, no gate | Remote pairing works for everyone; a "Sponsor" link in Settings. | No enforcement code. | No predictable revenue. Relay cost grows with use. |

Notes that apply to A and B:

- **Subscription or one-time** changes the relay check. A one-time purchase needs only a claim-time check. A subscription needs a re-check, for example when the Mac's socket connects with a token older than 30 days, and a grace period so a lapsed payment does not break a running job without warning.
- **Privacy.** The relay sees a license id (A) or an original transaction id (B) at each claim. Store only a hash, and only for counting machines.
- **Recommendation:** A, with B added later if the iPhone app becomes the main way people find stew. The decision belongs to the owner (question 9).

## 13. Phased plan

Estimates are in agent-waves: one wave is one dispatch of parallel builder agents plus their confirm pass.

### Phase 1: SSH forwarding and the Linux CLI

| Work item | Notes |
|---|---|
| Split the `stew` target into `StewCLI` (library), the macOS `stew` executable, and a Linux `stew` product | Section 9 table. |
| swift-crypto behind `canImport(CryptoKit)` in `StewLink` and `StewCore/Update.swift`; Linux-only package dependency | The iOS app also builds `StewLink` (`docs/PHONE.md:59`); check that it does not pull swift-crypto in. |
| Linux paths (XDG), `Glibc`, `/proc/self/exe`, `MSG_NOSIGNAL` | Section 9. |
| Remote mode in the CLI: socket from `remote.socket`, no daemon start, fast exit 4 | `Sources/stew/Client.swift:59-83`. |
| Per-remote listeners on the Mac, restricted controls, `session.host` set by the Mac | Sections 4 and 7. |
| `Responder` protocol in place of `Connection` for answers | Section 7. |
| Skip Mac-side grants and settings writes for remote requests; hide Allow next time for remote rows | Section 7 table. |
| Connection lost counts as late-answerable for remote requests | Section 4. |
| Waiting records, `late mail` control, remote-side grant writes for late approvals | Section 8. |
| Local list of the remote's own needs items for `UserPromptSubmit` | Section 10. |
| Machine chip in panel, History column, phone title | Section 7. |
| Per-machine limits and Mute | Section 6, rate limits table. |
| `stew remote add-ssh`, `stew remote remove`, `stew doctor` on the remote, docs in `docs/REMOTE.md` | Section 4. |
| Release: a Linux tarball (x86_64 and arm64) with a checksum and the release signature | Phase 1 has no auto-update on Linux. |

Tests:

- Unit tests in `StewCoreTests` and `StewLinkTests` run on Linux in CI (a `swift:6` container; stop it after the run).
- Envelope cross-check: a Linux-built `stew-test-phone fixture` output verifies on macOS and in the relay tests (`relay/README.md` Tests section, `relay/test/fixtures/swift-envelopes.json`).
- `Tests/e2e/run.sh` gains a remote case: a headless daemon with a remote listener, and the CLI pointed at it with `remote.socket` (the script already runs a headless daemon on its own socket, `Tests/e2e/run.sh:11`). Checks: label set by the Mac, restricted controls refused, grants written on the "remote" side only, `late mail` round trip, connection lost becomes answerable late.
- One real SSH test in a container with sshd and `StreamLocalBindUnlink yes`, forwarding to the headless daemon.

Risks:

- R1: swift-corelibs-foundation differences (regex, date formatting, `Process`) show up only at run time. Mitigation: run the full unit suite on Linux, not only a build.
- Users without `StreamLocalBindUnlink yes` hit stale sockets. Mitigation: `stew doctor` and clear docs.
- The target split touches every file in `Sources/stew`. Mitigation: do it as its own first commit with no behavior change, gated by the existing tests.

Estimate: 2 waves (wave 1: the split, Linux build, CI, paths; wave 2: listeners, labels, late mail, limits, tests and docs).

### Phase 2: relay pairing for remotes

| Work item | Notes |
|---|---|
| Relay: pairing kind in claim and row, `remote` side, per-kind `kindsBySender`, `late` kind, remote socket tag, `remote_outbox` with acks, remote request bucket, refusal of `/device` for remote pairings | Section 6. |
| `StewLink`: `LinkSide.remote`, `RemoteRequest`, `LinkLate`, claim text with kind, `t` in the pairing code; new phone app refuses remote codes | Sections 5 and 6. |
| `stew agent` on the remote: local socket server, relay socket with reconnect, long-poll fallback, on-demand start and idle exit, optional systemd unit | Section 9. |
| `stew remote pair` with echo-off code entry and digit display; `stew remote unpair`; `STEW_LINK_KEYS` | Section 5. |
| Mac: Settings ▸ Machines (pair, name, list, mute, unpair), relay `Responder`, `late` sending, key storage in the login keychain next to phone pairings | Sections 5, 7 and 11. |
| Docs: wire protocol additions in `docs/PHONE.md` or a new `docs/REMOTE.md`, relay README | |

Tests:

- Relay vitest: claim with kind, wrong-kind device registration refused, remote request forwarded or 503, outbox store and ack, `late` only from the Mac, unsupported kinds per pairing kind, the new bucket.
- `Tests/phone/run.sh` pattern extended: a local relay, a headless daemon, the Linux or macOS `stew agent` as the remote, and `stew-test-phone` answering a remote request from the phone. Checks the full path remote → Mac → phone → Mac → remote, a late answer delivered after the agent restarted, and unpair from each side.
- Fuzz-style checks that a remote envelope cannot carry an `answer` or `result`.

Risks:

- R2: `URLSessionWebSocketTask` on Linux. Mitigation: the long-poll fallback, and a spike at the start of the phase.
- Agent lifecycle on varied boxes (no systemd, read-only home, containers). Mitigation: on-demand start, clear errors, `STEW_LINK_KEYS`.
- Durable Object cost of long-lived remote sockets. Mitigation: WebSocket hibernation; measure before launch.

Estimate: 3 waves (relay and `StewLink`; agent and CLI pairing; Mac UI and the end-to-end harness).

### Phase 3: paid gating

| Work item | Notes |
|---|---|
| Token format, signing tool (as `_update-keygen` and `_sign-update` do for releases, `Sources/stew/main.swift:492-508`), embedded public key in the relay | Option A. |
| Relay check at claim for `kind: "remote"`, count per license hash, re-check rule if subscriptions | Section 12. |
| Mac: license entry in Settings ▸ Machines, state and errors; free SSH path never asks | |
| Issuing: checkout and email delivery of tokens, re-issue on request | Outside this repo. |
| Option B, if chosen: StoreKit 2 product in the iPhone app, JWS forwarded to the Mac, Apple chain check in the relay | |

Tests: token signature and expiry, machine count over the cap refused with a clear error, self-hosted relay with no check configured accepts remote claims, the Mac UI states.

Risks: the gate is easy to remove in the client, which is accepted by design (the relay is the gate). Refund and abuse handling are outside the code.

Estimate: 1 wave for option A in this repo; 1 more for option B.

## 14. Open questions for the owner

1. **Is a second Mac in scope for remote mode, or only Linux?** Recommendation: yes, the same `stew remote` commands on a Mac, because the code is the same and it lets one phone cover two Macs. Its own panel stays off while in remote mode.
2. **Should a dropped SSH connection make a request answerable late?** Recommendation: yes, for requests with a session id, labeled Connection lost in History. Background sessions in tmux keep running after SSH drops and can use the answer.
3. **Name of the Settings pane and of the concept: "Machines", "Remotes" or "Computers"?** Recommendation: Machines. It covers servers, VMs and Macs, and it is not a term stew uses for anything else.
4. **May a late secret sit encrypted in the relay outbox for up to 24 hours?** Recommendation: yes, with a 1 hour limit for secrets instead of 24. The alternative, secrets only while the agent is online, means a secret entered late is lost when the agent sleeps.
5. **Per-machine limits: 3 open asks and 10 open needs items, and Mute for 1 hour.** Recommendation: ship these numbers in config (`remote.maxOpen`, `remote.maxNeeds`) and adjust after use.
6. **Ephemeral cloud boxes: shared remote identity, pre-approved invitations, or neither in v1?** Recommendation: shared identity through `STEW_LINK_KEYS` only. Invitations without the six digits weaken pairing and can wait for a real need.
7. **Risk check for direct `stew permit` from a remote: on the Mac without session context, or off?** Recommendation: on the Mac, labeled "without the session's messages". A verdict from the remote cannot be trusted.
8. **Should the agent queue `needs` and `notify` while the Mac is offline?** Recommendation: yes, for up to 1 day, because these have no deadline and the job usually ends before the user is back.
9. **Paid gate: option A (Koode-signed token), B (iPhone in-app purchase), A then B, or D (sponsorship)? And one-time or subscription?** Recommendation: A first, one-time per major version with a machine cap (for example 5), because it works without an iPhone and needs only a claim-time check. Add B if most buyers come from the App Store.
10. **Do self-hosted relays get remote pairing with no check?** Recommendation: yes. The code is source-available and a client-side gate would be cosmetic; the hosted relay is what is sold.
11. **Linux distribution channel: tarball only, or also a `.deb`, a Homebrew on Linux formula, or an install script like the Mac's?** Recommendation: tarball plus the install script (`install.sh` already exists for the Mac) with a checksum check; packages later.
12. **Auto-update on Linux?** Recommendation: not in phase 1. `stew version` on the remote reports a version mismatch with the Mac (the request already carries the remote's version in phase 2), and the docs say how to update.
