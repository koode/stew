# stew on your iPhone

When a request stays open while you are away from your Mac, stew sends it to your iPhone as a notification you can answer. The answer goes back to the Mac, and Claude gets it as if you had answered in the panel.

## How it behaves

- **When it pushes.** A request goes to the phone once it has been open 10 seconds (`phone.after`) and the Mac is idle (no keyboard or mouse input for 2 minutes, `phone.idleAfter`) or its screen is locked. Settings ▸ iPhone ▸ Send requests offers "When I'm away" (the default), "Always" and "Never" (`phone.push`: `away`, `always`, `never`).
- **The time limit still applies.** The notification shows when the time to answer runs out. More time on the phone adds the same time as ⌘E on the Mac.
- **Late answers.** When the time runs out on a permission request, question or input from a Claude Code session, the phone can still answer it for 24 hours, like Answer now in the Mac's History: an open request screen stays open and says "Time ran out", and History lists the request with Answer now. Approve, Deny, the question's answers or a typed reply then go to the Mac, which passes them to the session as a late answer, exactly as if you answered from its History, and the phone shows "Sent as a late answer". The History row then shows the late outcome, such as "Approved late". More time cannot bring a request back, a secret is typed in the app's masked field, never in a notification, and Approve on a request auto mode never allows stays Mac-only. A request answered elsewhere or dismissed stays refused, and the phone says why. A request without a Claude session id (a `stew` call outside Claude Code) cannot take a late answer, so the phone refuses it as too late. The Mac remembers which phone may answer late only while it runs: after a restart, answer late on the Mac.
- **First answer wins.** When the request is answered anywhere (Mac, phone or another phone), times out or is dismissed, the phone's notification is replaced, without a sound, by one that says how it ended ("Answered on Studio", "Approved on Sam's iPhone", "Timed out", "Dismissed on Studio") and has no actions, so a stale Approve never remains. Opening the app clears those, and also clears the notification of any request that ended while no push could reach the phone, such as one that timed out while the Mac slept. A push for a request that already ended on the phone, such as a late update, never brings it back.
- **Opening a request stops the rush.** While a permission request, question or input is open on screen in the stew app, the Mac pauses its clock, the same as while you type a note on the Mac. The Mac panel shows "On <phone name>" with an iPhone symbol in place of the countdown, and the phone shows "No rush: the clock is paused while you answer." The clock runs again 30 seconds after you leave the request or put the app in the background, and other paired phones get the new deadline. Opening it again pauses it again, but only up to 15 minutes from the first open (Settings ▸ iPhone ▸ Longest pause while open on iPhone, `phone.viewingCap` in seconds); then the request times out, and Claude is told it was open on your iPhone that long. iOS does not tell the app when you expand a notification, so only an open request screen pauses the clock.
- **More time everywhere.** Permission, question and input notifications offer More time when the request has a time limit, and so do the request, question and input screens in the app. It works like ⌘E on the Mac.
- **Hard denies stay on the Mac.** A call auto mode never allows can be approved on the Mac only. The phone shows it and offers Deny and More time, but no Approve.
- **Severity.** The notification and the request screen show the risk check's level ("High risk") and its line on whether the action can be undone. For high and critical requests, the notification has no Approve: it offers Review, which opens the request in the app, plus Deny and More time. Approve in the app then shows a confirmation sheet that restates the action, the command (secrets masked) and the reversibility line, before Face ID or the passcode. For critical, you hold Approve down for about 1.5 seconds, and the sheet says it cannot be undone. Settings ▸ Claude Code ▸ Risk check ▸ Extra confirmation on iPhone sets which levels get the sheet: High and critical (the default), Critical only, or Off. The Mac refuses an approval of such a request that does not say it went through the sheet, so a stale notification action cannot skip it, and an app from before severity gets a refusal that asks to update it.
- **Approve needs an unlocked phone.** On a locked phone the Approve action asks for Face ID or the passcode first. On an unlocked phone, and on the Watch while it is unlocked on your wrist, iOS does not ask again. Approve in the app always asks. Deny and More time never ask.
- **Risk check first.** A request waits while its risk check runs, so the phone sees the verdict and a hard deny never arrives with an Approve.
- **Questions.** A single question offers its options (up to 4) and "Other…" with a text field. Several questions, or a multi-select question, open the app.
- **Inputs** (`stew input`) go out under the same rules as questions. The notification shows the question and why, with a **Reply** text field (its placeholder is the input's `--placeholder`). The app shows the same field. With `--pattern`, the phone refuses a reply that does not match before sending it, saying what is expected in the `--format` words when Claude gave them, and the Mac checks it again and refuses it too, so the request stays open for a reply that fits.
- **Secret inputs** (`--secret`) go out too. You type a secret on the Mac or in the stew app, never in a notification: a notification text field cannot hide what you type. The notification shows the question, why, and "Enter it on your Mac or in the stew app.", with three actions that need no Face ID. **Enter in app** opens the request in the app, which has a masked field checked against the same `--pattern` and `--format` as on the Mac. **Give me 5 min** adds 5 minutes to the clock on the Mac and on the phone. **I'll enter it later** ends Claude's wait at once with `"status":"later"`; you then enter the secret on the Mac from History ▸ Answer now, or in the app from its History, and it reaches the session as a late answer. A secret typed in the app goes to the Mac end-to-end encrypted like any answer, and the phone never writes it anywhere: not to its shared state, its history, its notifications or its logs. The Mac checks it again and handles it exactly like a secret typed in its panel: never in its history, logs or files, and a late one held in the daemon's memory only, until the session's next hook fetches it. The Mac never sends a secret to the phone, and it refuses a secret sent as a plain reply. A Mac from before this feature does not mark its secrets as enterable in the app, so the app then shows "Enter it on your Mac" without a field.
- **Notifications** (`stew notify`) arrive without actions.
- **stew's own notices stay on the Mac.** The notices stew shows by itself, "stew updated to 0.2.0", "stew 0.2.0 is available" and "3 requests timed out while you were away", are about the Mac and never go to the phone.
- **Needs items** (`stew needs`) go out once they have been open 10 seconds, also while you are at the Mac, because they have no deadline and the task often takes you away from the desk. "Never" still sends none. The notification shows the title, why, the steps and the commands with secrets masked, with Done and Not now. When Claude named the Done button (`--done`) or offered other answers (`--answer`), the actions carry those labels: Done with its label, each other answer, then Not now, in a notification category made for that item. Done and the other answers need no Face ID; Done ends the item on the Mac as Done, another answer ends it as Answered, and Claude learns which label was picked. The Mac takes an answer only when the item offers that label, so an answer from a stale or forged notification is refused. Done keeps its old form on the wire, so an iPhone app from before the labels still ends such an item with Done. Not now only clears the notification; the item stays open on the Mac. An item you parked with Not now on the Mac is not sent. The phone's history uses the Mac's labels: Done, Dismissed, Resolved by Claude, Answered in session, Moved on.
- **Apple Watch** shows the same actions, without a watch app.

## Pairing

1. On the Mac: Settings ▸ iPhone ▸ Pair an iPhone. stew shows a QR code. The same code is a `stew://pair?code=…` link that you can copy and paste on the phone instead. The code works for 10 minutes and for one phone; Settings counts down the time it has left. A copied code leaves the clipboard after a minute.
2. On the iPhone: in the stew app, tap Pair a Mac and scan the code, or paste it.
3. The iPhone shows six digits. Type them on the Mac. The Mac never shows them, so they can only come from your phone. If the phone shows none (another device used the code first), reject on the Mac.

![Settings ▸ iPhone while a code waits to be scanned](images/settings-phone-pairing-light.png)

![The iPhone shows six digits](images/iphone-app-pair-verify-light.png)

![Settings ▸ iPhone asks for the six digits](images/settings-phone-confirm-light.png)

A Mac can pair with several phones and a phone with several Macs. Each pairing has its own id, its own pairing secret and its own key. Unpairing on either side removes the pairing on both.

## Configuration

The `phone` object in `~/.config/stew/config.json`. Every field is optional.

```json
{ "phone": { "push": "away", "after": 10, "idleAfter": 120, "relay": "https://relay.stewcli.com" } }
```

- `push`: `away`, `always` or `never`. An unknown value counts as `away`.
- `after`: seconds a request must be open before it is sent. `0` sends it at once (stew checks every second). Settings offers Instantly, 3, 5, 10 and 30 seconds, 1 and 2 minutes.
- `idleAfter`: seconds without keyboard or mouse input before the Mac counts as away.
- `relay`: the relay for new pairings, `https://relay.stewcli.com` by default. Each pairing keeps the relay it was made with, so change this before pairing.

## iPhone app

The stew app for the iPhone (`nl.koode.stew.ios`) and its notification service extension use the same `StewLink` code as the Mac for every message, key and sentence, so the phone and the Mac say the same thing. The app is not in this repository; it is distributed through TestFlight while stew is in beta.

![A permission request on the iPhone, with its actions](images/iphone-notification-expanded-permission-light.png)

Needs items show the same parts as the Mac panel: the title, Why, the steps, the commands with secrets masked, and the links. Done (with Claude's label for it) and the other answers tell Claude how to go on and ask for no Face ID, because they run nothing. Not now sends nothing: the notification goes, and the item stays in Requests and on the Mac. Needs items have no time limit, so they never show as missed.

![A needs item on the iPhone, with Done and Not now](images/iphone-notification-expanded-needs-light.png)

Questions follow the Mac panel's rules: a single-select option answers and moves on, multi select toggles until Confirm, and Other… takes typed text. The last question of a set always shows Submit, so a send that failed can be tried again. Submit or Confirm while a question has no answer goes to the first open question and says so ("Q1 has no answer yet."), as ⌘↩ does on the Mac; it never does nothing. While the answer goes out the button shows "Sending…". When it fails or the Mac refuses it, the reason shows on the screen under the buttons, which scroll into view, and the answers stay as they were for another try. The Mac also writes every refusal of a phone answer to its log.

![Submit with a question left open](images/iphone-app-question-incomplete-light.png)

![An answer that could not reach the Mac](images/iphone-app-question-send-error-light.png)

![An answer after the time ran out, sent as a late answer](images/iphone-app-question-late-sent-light.png)

Inputs show the question, Why and an Answer field; Send stays off until the answer fits the pattern. A secret shows a masked Secret field with Send, and Give me 5 min and I'll enter it later under it. From an older Mac it shows "Enter it on your Mac" with only those two.

![A secret input on the iPhone, with its masked field, Give me 5 min and I'll enter it later](images/iphone-app-secret-light.png)

An iPhone app from before inputs cannot read an input request: its notification keeps the relay's generic text ("A request is waiting on your Mac."), and its Requests list skips it. Answer it on the Mac, or update the app.

## Security

- **End to end.** Every message is encrypted with ChaCha20-Poly1305 and signed with the sender's Ed25519 key. The key comes from HKDF-SHA256 over the X25519 shared secret of the two devices, salted with the 32 byte pairing secret from the QR code.
- **What the relay sees.** The pairing id, the phone's push token, the public keys, and for each message: its kind (request, update, resolved, answer, result, hello, unpair), the sender side (mac or phone), the request id, the message id and the expiry. It never sees the session, the command, the question or the answer. Plaintext is padded to 256 byte blocks, so message sizes do not tell approve from deny. Message order still shows one thing: More time is followed by an update, a final answer by a resolved message.
- **What the relay cannot do.** It cannot read or forge a request or an answer: it does not have the pairing secret, so it cannot derive the key, and it does not have the private signing keys. A relay that swapped in its own keys during pairing would fail on the encryption, and the six digits would not match. A relay that holds an answer back cannot apply it later: the Mac refuses answers more than 30 seconds old.
- **Replays.** Each message has a unique id and an expiry. The receiver refuses expired messages and message ids it has already seen, and the Mac takes only the first answer to a request. The Mac keeps seen ids in memory only; request ids are new each run, so an answer from before a restart finds nothing to answer.
- **Keys.** On the Mac, the private keys and pairing records are in the login keychain (service `nl.koode.stew.link`). On the iPhone they are in the app group keychain shared by the app and its notification extension.
- **No self-approval.** A phone counts only after the user types its digits on the Mac. A process on the Mac that took a copied code and registered first gets no further: the real phone shows no digits, so there is nothing to type. Pairing through the socket exists only in the headless test daemon.

## Wire protocol

This section is the contract between the Mac, the relay and the phone. Swift types are in `Sources/StewLink`.

### Encodings

- JSON bodies carry binary fields (keys, ciphertext, signatures) as standard base64 with padding.
- The `authorization` header carries its nonce and signature as base64url without padding.
- Ids (pairing, request, message) are 1 to 64 characters of `A-Z a-z 0-9 - _`.
- Times on the wire are Unix seconds.

### Envelope

```json
{ "v": 1, "pairingId": "…", "kind": "request", "sender": "mac", "requestId": "…",
  "messageId": "…", "replyTo": "", "expiresAt": 1800000000,
  "ciphertext": "<base64>", "signature": "<base64>" }
```

- `kind`: `hello`, `request`, `update`, `resolved`, `answer`, `result`, `unpair`.
- `sender`: `mac` or `phone`.
- `requestId`: the request the message is about; `pairing` for hello and unpair.
- `replyTo`: for a result, the message id of the answer it replies to; empty otherwise.
- `ciphertext`: ChaCha20-Poly1305 combined box (12 byte nonce, ciphertext, 16 byte tag). The associated data is the header below.
- Header: the lines `stew-link/1`, pairingId, kind, sender, requestId, messageId, replyTo, expiresAt, joined with `\n`.
- `signature`: Ed25519 over the header, `\n`, and the ciphertext as the same base64 text the JSON carries.

### Relay

The relay forwards envelopes between the two devices and sends Apple push notifications to the phone. It cannot read or forge them (see Security). The relay protocol has a version of its own, separate from the envelope's `v`: stew speaks version 2, and version 1 with a relay from before version 2. Its paths start with `/v2/pairings/{pairingId}`:

| Method and path | Caller | What it does |
|---|---|---|
| `GET /v2/info` | anyone | Lists the protocol versions the relay serves, with its limits and timers |
| `POST /claim` | Mac | Claims a new pairing id with the Mac's signing key and the SHA-256 of a registration token derived from the pairing secret |
| `POST /device` | phone | Registers the phone's push token and keys with that token (once), later updates the push token with a signed call |
| `GET /socket` | Mac | The Mac's WebSocket (subprotocol `stew.relay.2`), on which the relay passes on the phone's hello, answers and unpair |
| `POST /messages` | either | Takes an envelope. A Mac request is stored until it is resolved and pushed to the phone; a phone answer goes to the Mac and waits up to 10 seconds for the Mac's result |
| `GET /pending` | phone | Returns the open and recently resolved requests |

- Before it claims a pairing id or connects, stew asks `GET /v2/info`. It speaks v2 when the relay lists 2, and v1 only when the relay has no `/v2/info`. A relay that answered v2 once is not talked down to v1.
- Calls without an envelope carry `authorization: Stew-Ed25519 side=…, ts=…, nonce=…, sig=…`: an Ed25519 signature over the method, path, side, time, a random nonce and the SHA-256 of the body. The relay refuses a time more than 300 seconds off and a nonce it has seen. No credential is ever in a URL.
- The relay checks every envelope's fields, its expiry (at most 7 days ahead), its signature against the sender's stored key and its message id, and limits the rate per pairing and per client address. The same envelope sent again gets its first outcome back, so a phone that lost the response to an answer sends it again and gets the Mac's result, which the relay keeps.
- Every frame on the Mac's socket has a `seq`. The Mac acks the highest one it has handled, and on each connect the relay sends every frame above the last ack again, so nothing for the Mac is lost on a dropping socket.
- The Mac pings every 25 seconds and reconnects when no pong comes within 10. It acts on the relay's close codes: after an unpair it stops and forgets the pairing, after a replaced socket it waits a minute.
- A push carries the envelope when it fits in 4 KB; otherwise the notification extension fetches it from `GET /pending`. When a request ends, a closed push replaces its notification without a sound and without actions. `resolved` is final: an update that arrives after it changes nothing.

The Mac's side is in `Sources/StewLink` (the v2 header, frames and close codes in `RelayProtocol.swift`), `Sources/stew/RelayConnection.swift` and `Sources/stew/PhoneLink.swift`.
