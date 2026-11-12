# Releasing stew

Releases are served from the R2 bucket `stew-releases` at `https://releases.stewcli.com`:

| Object | Cache | Changes |
|---|---|---|
| `v<version>/Stew-<version>.zip` | `public, max-age=31536000, immutable` | Never. A version folder is written once. |
| `latest.json` | `no-store` | Every release. It is the only object that moves. |
| `install.sh` | `public, max-age=300` | When `scripts/install-release.sh` changes. |

`scripts/release.sh` builds, signs, notarizes, signs the zip for the updater and uploads. It needs Xcode, the 1Password CLI (`op`), pnpm and a wrangler login for the Koode Cloudflare account.

## Once: the update signing key

The updater installs a zip only when it carries an Ed25519 signature from the release key. The public half is compiled into stew; the private half lives only in 1Password.

1. Run `scripts/release.sh keygen`. It makes the key pair and stores the private key as "stew release signing key" in your Private vault (1Password asks for Touch ID). The private key goes from stew to `op` through a pipe: it is never written to disk or printed. The command refuses to run when that item already exists.
2. Paste the public key it prints into `Sources/stew/Updater.swift`:
   ```swift
   static let embeddedPublicKey = "<public key>"
   ```
3. Commit that change. `scripts/release.sh` refuses to run while the constant is empty.

Replacing the key later breaks updates for every installed copy that trusts the old key: those users have to reinstall with the install script. Keep the 1Password item.

## Every release

1. Bump `VERSION` (for example `0.2.0`) and commit. The build number is the commit count of `HEAD`, so it grows on its own; keep `main` linear.
2. Optional: `scripts/release.sh --dry-run`. It builds, signs ad hoc with a throwaway update key and writes everything to `build/dist`, without notarizing or uploading. Inspect `build/release/Stew.app` and `build/dist/latest.json`.
3. From a clean checkout of the commit to release, run `scripts/release.sh`. It:
   1. checks that `v<version>/` does not exist in the bucket yet, and stops if it does;
   2. builds a universal binary (arm64 and x86_64) and assembles `Stew.app`;
   3. signs it with `Developer ID Application: Koode (PXD36584ME)` (`STEW_SIGN_IDENTITY`), hardened runtime and a secure timestamp;
   4. notarizes it with `xcrun notarytool submit --keychain-profile stew-notary --wait` (`STEW_NOTARY_PROFILE`) and staples the ticket;
   5. zips it with `ditto -c -k --keepParent`, and signs the zip with the key from `op read "op://Private/stew release signing key/private key"` (`STEW_SIGNING_KEY_REF`), piped into `stew _sign-update`;
   6. checks that signature against the public key in the build, and writes `latest.json`;
   7. uploads the zip, then `install.sh`, then `latest.json` last, so the manifest never points at a missing zip.
4. Verify:
   ```bash
   curl -fsSL https://releases.stewcli.com/latest.json
   stew update --check     # on a Mac with the previous version: exit 10, "is available"
   stew update             # installs it and restarts the daemon
   stew version
   ```
5. Tag the commit: `git tag v<version> && git push origin v<version>`.

## How updates work

- The daemon checks `latest.json` one minute after it starts, then whenever a day has passed since the last check, while "Install updates automatically" is on (`"autoUpdate": true`, the default). `stew update` checks and installs now; `stew update --check` only reports. Settings ▸ General shows the version, the last check and a Check now button.
- A newer version wins; for the same version, the higher build wins. A release whose `minimumMacOS` is newer than the Mac's is skipped.
- The zip must match the size and SHA-256 in `latest.json` and carry a valid Ed25519 signature from the release key. The unzipped app must be `nl.koode.stew` with the version and build from the manifest, and pass `codesign --verify --deep --strict` with a Developer ID from team PXD36584ME.
- The download and unzip happen in `~/Applications/.stew-update`. The app is swapped only while no request is open in the panel: the installed app moves to `.stew-update/backup`, the new one moves in, and the backup moves back if that fails. Then `launchctl kickstart -k` restarts the daemon on the new binary, and the new daemon removes `.stew-update`.
- Every step is logged to `~/Library/Logs/stew.log` with the prefix `update:`.

## Rolling back a bad release

Version folders never change, so the previous zip is still published. Point `latest.json` back at it:

1. Fetch the previous release's manifest values: its version, build, zip URL, sha256, size and ed25519 signature. Keep each release's `build/dist/latest.json`, or recompute sha256 and size from the published zip; the signature can be made again with `op read "$STEW_SIGNING_KEY_REF" | stew _sign-update Stew-<version>.zip`.
2. Copies that already installed the bad version do not go back on their own, because the updater only moves forward. To move them on, release a fixed version with a higher version number (or the same version with a higher build).
3. To stop new installs and pending updates from getting the bad version right away, upload the previous manifest:
   ```bash
   CLOUDFLARE_ACCOUNT_ID=YOUR_ACCOUNT_ID pnpm dlx wrangler r2 object put \
     stew-releases/latest.json --file previous-latest.json \
     --content-type application/json --cache-control no-store --remote
   ```
4. Never delete or overwrite a `v<version>/` folder. Release the fix as a new version.
