# stew on your iPhone

When a request stays open while you are away from your Mac, stew sends it to your iPhone as a notification you can answer. The answer goes back to the Mac, and Claude gets it as if you had answered in the panel.

## How it behaves

- **When it pushes.** A request goes to the phone once it has been open 10 seconds (`phone.after`) and the Mac is idle (no keyboard or mouse input for 2 minutes, `phone.idleAfter`) or its screen is locked. Settings ▸ iPhone ▸ Send requests offers "When I'm away" (the default), "Always" and "Never" (`phone.push`: `away`, `always`, `never`).
- **The time limit still applies.** The notification shows when the time to answer runs out. An answer that arrives later is refused, and the phone says so. More time on the phone adds the same time as ⌘E on the Mac.
- **First answer wins.** When the request is answered anywhere (Mac, phone or another phone), times out or is dismissed, the other devices remove their notification.
- **Hard denies stay on the Mac.** A call auto mode never allows can be approved on the Mac only. The phone shows it and offers Deny and More time, but no Approve.
- **Approve needs Face ID.** The Approve action asks for Face ID or the passcode first. Deny and More time do not.
- **Questions.** A single question offers its options (up to 4) and "Other…" with a text field. Several questions, or a multi-select question, open the app.
- **Notifications** (`stew notify`) arrive without actions.
- **Apple Watch** shows the same actions, without a watch app.

## Pairing

1. On the Mac: Settings ▸ iPhone ▸ Pair an iPhone. stew shows a QR code. The same code is a `stew://pair?code=…` link that you can copy and paste on the phone instead.
2. On the iPhone: in the stew app, tap Pair a Mac and scan the code, or paste it.
3. Both screens show the same six digit code. Check that they match, then click Confirm on the Mac.

A Mac can pair with several phones and a phone with several Macs. Each pairing has its own id, its own pairing secret and its own key. Unpairing on either side removes the pairing on both.

## Security

- **End to end.** Every message is encrypted with ChaCha20-Poly1305 and signed with the sender's Ed25519 key. The key comes from HKDF-SHA256 over the X25519 shared secret of the two devices, salted with the 32 byte pairing secret from the QR code.
- **What the relay sees.** The pairing id, the phone's push token, the public keys, and for each message: its kind (request, update, resolved, answer, result, hello, unpair), the sender side (mac or phone), the request id, the message id and the expiry. It never sees the session, the command, the question or the answer.
- **What the relay cannot do.** It cannot read or forge a request or an answer: it does not have the pairing secret, so it cannot derive the key, and it does not have the private signing keys. A relay that swapped in its own keys during pairing would fail on the encryption, and the six digit codes would differ.
- **Replays.** Each message has a unique id and an expiry. The receiver refuses expired messages and message ids it has already seen, and the Mac takes only the first answer to a request.
- **Keys.** On the Mac, the private keys and pairing records are in the login keychain (service `nl.koode.stew.link`). On the iPhone they are in the app group keychain shared by the app and its notification extension.
- **No self-approval.** Pairing needs the code shown in the settings window and a click on Confirm with matching digits, so a process on the Mac cannot pair a phone of its own.

## Wire protocol

This section is the contract between the Mac, the relay and the phone. Swift types are in `Sources/StewLink`.

### Encodings

- JSON bodies carry binary fields (keys, ciphertext, signatures) as standard base64 with padding.
- Query strings carry signatures as base64url without padding.
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

### Relay endpoints

All paths start with `/v1/pairings/{pairingId}`. The relay keeps one Durable Object per pairing id. Signed GET requests carry `?ts=<unix seconds>&sig=<base64url>`; the relay refuses a timestamp more than 300 seconds from its clock.

| Method and path | Caller | Body or auth | Result |
|---|---|---|---|
| `POST /claim` | Mac | `{macSigningKey, registrationTokenHash, timestamp, signature}`, signed text `stew-link/1 claim\n{id}\n{hash}\n{ts}` | 201 claimed, 200 already this Mac's, 409 another key holds it |
| `POST /device` | phone, first time | `{registrationToken, deviceToken, environment, phoneKeys, hello}` | 201; 403 wrong token; 409 already used |
| `POST /device` | phone, later | `{deviceToken, environment, timestamp, signature}`, signed text `stew-link/1 device\n{id}\n{deviceToken}\n{environment}\n{ts}` | 200 |
| `GET /socket` | Mac | WebSocket; signed text `stew-link/1 socket\n{id}\n{ts}` | frames to the Mac |
| `POST /messages` | either | an envelope | see below |
| `GET /pending` | phone | signed text `stew-link/1 pending\n{id}\n{ts}` | `{requests: [envelope], resolved: [envelope]}` |
| `GET /v1/test/pushes/{pairingId}` | tests | only with `MOCK_APNS=1` | `{pushes: [{at, host, path, headers, payload}]}` |

- `registrationTokenHash` is the lowercase hex SHA-256 of the registration token's UTF-8 text. The token is base64url of HKDF-SHA256 over the pairing secret with info `stew-link/1 registration`. The relay deletes the hash once a phone has registered, so a code pairs one phone.
- `environment` is `production` or `sandbox` and picks the APNs host.
- The hello envelope must be signed by `phoneKeys.signing`. The relay passes it on to the Mac as `{"type":"hello","envelope":…,"phoneKeys":…}`.

`POST /messages` checks the envelope's fields, that its pairing id matches the path, its expiry (not past, at most 7 days ahead), its signature against the stored key of the sender, that its message id is new, and the pairing's rate limit (429 with Retry-After). Then:

| Sender and kind | What the relay does |
|---|---|
| mac `request` | Stores it as pending, sends an alert push. 202, or 409 `no_device` |
| mac `update` | Replaces the pending copy, sends a background push. 202 |
| mac `resolved` | Drops the pending copy, keeps the envelope for an hour, sends a background push. 202 |
| mac `result` | Hands it to the phone's waiting answer with that `replyTo`. 202 |
| mac `unpair` | Sends a background push, then deletes the pairing. 202 |
| phone `answer` | Sends `{"type":"envelope","envelope":…}` on the Mac's socket and waits up to 10 seconds for the result. 200 `{result: envelope}`, 503 `mac_offline`, 504 `mac_timeout` |
| phone `unpair` | Passes it on to the Mac (queued if it is offline), then deletes the phone's data. 202 |

### Pushes

The relay signs an ES256 JWT with the APNs key (`APNS_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`) and posts to `https://api.push.apple.com/3/device/{token}` (`api.sandbox.push.apple.com` for sandbox tokens) with topic `APNS_TOPIC`.

Alert push, for `request`:

```json
{ "aps": { "alert": { "title": "stew", "body": "A request is waiting on your Mac." },
           "mutable-content": 1, "sound": "default", "thread-id": "<pairingId>" },
  "stew": { "pairingId": "…", "requestId": "…", "kind": "request", "envelope": { … } } }
```

Headers: `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: <expiresAt>`, `apns-collapse-id: <requestId>`. When the payload would exceed 4 KB, `envelope` is left out and the notification extension fetches it from `GET /pending`.

Background push, for `update`, `resolved` and `unpair`: `{"aps":{"content-available":1},"stew":{…}}` with `apns-push-type: background` and `apns-priority: 5`.

The notification extension decrypts the envelope and replaces the generic text with the request itself. If it cannot, the generic text stays.
