# Releasing stew

Releases are served from the R2 bucket `stew-releases` at `https://releases.stewcli.com`:

| Object | Cache | Changes |
|---|---|---|
| `v<version>/Stew-<version>.zip` | `public, max-age=31536000, immutable` | Never. A version folder is written once. |
| `latest.json` | `no-store` | Every release. It is the only object that moves. |
| `install.sh` | `public, max-age=300` | When `scripts/install-release.sh` changes. |

`scripts/release.sh` builds, signs, notarizes, signs the zip for the updater and uploads. It needs Xcode, the 1Password CLI (`op`), pnpm, a wrangler login, and `CLOUDFLARE_ACCOUNT_ID` set to the Cloudflare account that holds the `stew-releases` bucket.

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

1. Bump `VERSION` (for example `0.2.0`) and `"version"` in `plugin/.claude-plugin/plugin.json` to the same value, and commit. Claude Code updates the plugin only when that version changes; a unit test fails while the two differ. The build number is the commit count of `HEAD`, so it grows on its own; keep `main` linear.
2. Optional: `scripts/release.sh --dry-run`. It builds, signs ad hoc with a throwaway update key and writes everything to `build/dist`, without notarizing or uploading. Inspect `build/release/Stew.app`, `build/dist/latest.json` and `build/dist/stew.rb`. A dry run never writes into the tap, even with `--tap-dir`.
3. From a clean checkout of the commit to release, run `scripts/release.sh --tap-dir ~/code/homebrew-apps` (a checkout of the tap, see below). It:
   1. checks that `v<version>/` does not exist in the bucket yet, and stops if it does;
   2. builds a universal binary (arm64 and x86_64) and assembles `Stew.app`;
   3. signs it with `Developer ID Application: Koode (PXD36584ME)` (`STEW_SIGN_IDENTITY`), hardened runtime and a secure timestamp;
   4. notarizes it with `xcrun notarytool submit --keychain-profile stew-notary --wait` (`STEW_NOTARY_PROFILE`) and staples the ticket;
   5. zips it with `ditto -c -k --keepParent`, and signs the zip with the key from `op read "op://Private/stew release signing key/private key"` (`STEW_SIGNING_KEY_REF`), piped into `stew _sign-update`;
   6. checks that signature against the public key in the build, and writes `latest.json`;
   7. writes the Homebrew cask for this release to `build/dist/stew.rb` (`scripts/render-cask.sh` fills in `packaging/homebrew/stew.rb.template` with the version and the zip's sha256) and checks its Ruby syntax;
   8. uploads the zip, then `install.sh`, then `latest.json` last, so the manifest never points at a missing zip;
   9. with `--tap-dir`, copies the cask to `Casks/stew.rb` in the tap, after the upload, so the tap never names a zip that is not there. Without it, the script says where the cask is.
4. Publish the cask: commit `Casks/stew.rb` in the tap and push it (the script prints the commands). The script never pushes. Until the tap has the new cask, `brew install --cask koode/apps/stew` installs the previous version, which then updates itself.
5. Verify:
   ```bash
   curl -fsSL https://releases.stewcli.com/latest.json
   stew update --check     # on a Mac with the previous version: exit 10, "is available"
   stew update             # installs it and restarts the daemon
   stew version
   brew update && brew info --cask koode/apps/stew   # the tap names the new version
   ```
6. Tag the commit: `git tag v<version> && git push origin v<version>`.

## The Homebrew tap

The cask lives in the tap `koode/apps`, the public repository `github.com/koode/homebrew-apps`, as `Casks/stew.rb` with the token `stew`. Users install with `brew trust --cask koode/apps/stew && brew install --cask koode/apps/stew`: Homebrew 7 loads a cask from a tap other than its own only once it is trusted. Never edit `Casks/stew.rb` by hand: change `packaging/homebrew/stew.rb.template` here and let the next release write it.

What the cask does:

| Stanza | What it does |
|---|---|
| `app`, `binary`, `*_completion` | Moves Stew.app to `/Applications` (the user's `--appdir`), links `stew` into Homebrew's `bin`, and links the completion scripts the app carries (see below) |
| `auto_updates true` | stew updates itself, so `brew upgrade` skips it unless `--greedy`, and `brew outdated` still lists it |
| `depends_on macos: :sonoma` | macOS 14, the same minimum as `LSMinimumSystemVersion` |
| `preflight` | Runs the new app's `stew completions uninstall`: completion files an earlier install from the script wrote can stand where Homebrew links its own, and Homebrew refuses to overwrite them |
| `postflight` | Runs `stew setup`: the LaunchAgent, the daemon and the skill. No hooks, no `~/.local/bin` link, no completion files |
| `uninstall launchctl:` | Stops the daemon and removes the LaunchAgent. Homebrew runs this on `brew upgrade` too; the new version's `postflight` sets it up again |
| `zap` | Runs `stew uninstall --keep-app` (hooks, skill, stored approvals, iPhone pairings), then trashes `~/.config/stew`, the support folder, the caches and the log |

`stew setup` knows a cask install by two things together: a `Caskroom/stew` folder under a Homebrew prefix (`HOMEBREW_PREFIX`, `/opt/homebrew`, `/usr/local`), and that prefix's `bin/stew` link leading to the running app's tool. The link is what Homebrew provides in place of `~/.local/bin/stew`, so it is also the reason setup adds no link and no completion files.

## How updates work

- The daemon checks `latest.json` one minute after it starts, then whenever a day has passed since the last check, while "Install updates automatically" is on (`"autoUpdate": true`, the default). `stew update` checks and installs now; `stew update --check` only reports. Settings ▸ General shows the version, the last check and a Check now button.
- "Check now" in Settings only checks; "Install now" next to the result installs. Only an app signed with the Koode Developer ID installs updates at all; a build from source checks and reports, and Settings tells the user to rebuild.
- A newer version wins; for the same version, the higher build wins. A release whose `minimumMacOS` is newer than the Mac's is skipped.
- The zip must match the size and SHA-256 in `latest.json` and carry a valid Ed25519 signature from the release key. The unzipped app must be `nl.koode.stew` with the version and build from the manifest, and pass `codesign --verify --deep --strict` with a Developer ID from team PXD36584ME.
- The updater replaces the app it runs from: `~/Applications/Stew.app` from the script, `/Applications/Stew.app` from the cask, or wherever the user moved it. It never puts a second copy in `~/Applications`. If this user cannot write to the app's folder, the update is reported as available (exit 10) with what to do instead: `brew upgrade --cask stew` for a cask install, otherwise the folder it cannot write to. Settings shows the same and hides Install now.
- The download and unzip happen in `.stew-update` next to the app (`~/Applications/.stew-update` for the script's install). The app is swapped only while no request is open in the panel: the installed app moves to `.stew-update/backup`, the new one moves in, and the backup moves back if that fails. Then `launchctl kickstart -k` restarts the daemon on the new binary, and the new daemon removes `.stew-update`.
- Every step is logged to `~/Library/Logs/stew.log` with the prefix `update:`.

## Rolling back a bad release

Version folders never change, so the previous zip is still published. Point `latest.json` back at it:

1. Fetch the previous release's manifest values: its version, build, zip URL, sha256, size and ed25519 signature. Keep each release's `build/dist/latest.json`, or recompute sha256 and size from the published zip; the signature can be made again with `op read "$STEW_SIGNING_KEY_REF" | stew _sign-update Stew-<version>.zip`.
2. Copies that already installed the bad version do not go back on their own, because the updater only moves forward. To move them on, release a fixed version with a higher version number (or the same version with a higher build).
3. To stop new installs and pending updates from getting the bad version right away, upload the previous manifest:
   ```bash
   pnpm dlx wrangler r2 object put \
     stew-releases/latest.json --file previous-latest.json \
     --content-type application/json --cache-control no-store --remote
   ```
4. Never delete or overwrite a `v<version>/` folder. Release the fix as a new version.

## Shell completion in a Homebrew cask

A cask never runs `stew`, so it cannot call `stew completions install`. Instead, `scripts/build-app.sh` puts the generated scripts in the app, in `Contents/Resources/completions` (`_stew`, `stew.fish` and `stew` for bash), and the cask links them with its completion stanzas, the way the Docker cask does:

```ruby
app "Stew.app"
binary "#{appdir}/Stew.app/Contents/MacOS/stew"
zsh_completion "#{appdir}/Stew.app/Contents/Resources/completions/_stew"
fish_completion "#{appdir}/Stew.app/Contents/Resources/completions/stew.fish"
bash_completion "#{appdir}/Stew.app/Contents/Resources/completions/stew"
```

Homebrew links them into its `share/zsh/site-functions`, `share/fish/vendor_completions.d` and `etc/bash_completion.d`, which zsh (through `brew shellenv`) and fish load, and removes the links on `brew uninstall`. The links point into the app, so a new version of the app brings its own scripts. Do not run `stew completions install` from a `postflight`: it writes copies into the user's home that `brew uninstall` would leave behind. For the same reason, `stew setup` writes no completion files for a cask install.
