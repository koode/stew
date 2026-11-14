#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a stew release. docs/RELEASING.md has the steps.
#
#   scripts/release.sh             the real release, from a clean checkout
#   scripts/release.sh --dry-run   everything on this Mac: ad hoc signing, a throwaway
#                                  update key, no notarization, no upload. Output in build/dist.
#   scripts/release.sh keygen      once: make the update signing key and store it in 1Password
#
#   --tap-dir PATH   a checkout of the koode/homebrew-apps tap: after the upload, the
#                    Homebrew cask for this release goes to PATH/Casks/stew.rb, to commit
#                    and push there. Without it, the script says where the cask would go.
#                    A dry run never writes there. The cask is always in build/dist/stew.rb.
#
# Environment (defaults in brackets):
#   STEW_SIGN_IDENTITY     [Developer ID Application: Koode (PXD36584ME)]
#   STEW_NOTARY_PROFILE    [stew-notary] a `xcrun notarytool store-credentials` profile
#   STEW_SIGNING_KEY_REF   [op://Private/stew release signing key/private key]
#   STEW_SIGNING_VAULT     [Private] the vault keygen writes to
#   STEW_R2_BUCKET         [stew-releases]
#   CLOUDFLARE_ACCOUNT_ID  the account that holds the stew-releases bucket; needed to upload
#
# Published objects under v<version>/ never change: the script stops when that folder
# already exists. Only latest.json moves, and it is uploaded last, so a failed run
# never points users at a zip that is not there.
#
# Needs Xcode, and for a real release also op (1Password CLI), pnpm and an
# authenticated wrangler. Does not use sudo.
set -euo pipefail

readonly project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

readonly sign_identity="${STEW_SIGN_IDENTITY:-Developer ID Application: Koode (PXD36584ME)}"
readonly notary_profile="${STEW_NOTARY_PROFILE:-stew-notary}"
readonly signing_key_ref="${STEW_SIGNING_KEY_REF:-op://Private/stew release signing key/private key}"
readonly signing_vault="${STEW_SIGNING_VAULT:-Private}"
readonly signing_key_title="stew release signing key"
readonly bucket="${STEW_R2_BUCKET:-stew-releases}"
readonly account_id="${CLOUDFLARE_ACCOUNT_ID:-}"
readonly team_id="PXD36584ME"
readonly public_base="https://releases.stewcli.com"

readonly build_dir="$project_root/build/release"
readonly dist_dir="$project_root/build/dist"

step() { printf '==> %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

mode="release"
tap_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) mode="dry-run" ;;
    keygen) mode="keygen" ;;
    --tap-dir)
      [[ $# -ge 2 && -n "$2" ]] || fail "--tap-dir needs a path"
      tap_dir="$2"; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown argument: $1 (use --dry-run, keygen, --tap-dir PATH or nothing)" ;;
  esac
  shift
done
if [[ -n "$tap_dir" ]]; then
  [[ -d "$tap_dir" ]] || fail "--tap-dir $tap_dir is not a folder"
  tap_dir="$(cd "$tap_dir" && pwd)"
fi

# The public key compiled into the updater. Empty until keygen has run.
embedded_public_key() {
  sed -n 's/.*static let embeddedPublicKey = "\(.*\)".*/\1/p' Sources/stew/Updater.swift
}

r2() {
  [ -n "$account_id" ] || fail "set CLOUDFLARE_ACCOUNT_ID to the Cloudflare account that holds the stew-releases bucket"
  # stdin from /dev/null: run from a terminal, a tool in the pnpm dlx chain otherwise
  # tries to ask a question, and fails with "not a terminal" because the output is
  # captured.
  CLOUDFLARE_ACCOUNT_ID="$account_id" pnpm dlx wrangler r2 object "$@" --remote < /dev/null
}

# Exits 0 when the object exists, 1 when R2 says it does not. Anything else (no login,
# no network) stops the release, so an unclear answer never leads to an overwrite.
r2_exists() {
  local output
  if output="$(r2 get "$bucket/$1" --pipe 2>&1 > /dev/null)"; then
    return 0
  fi
  if grep -qiE "does not exist|not found|NoSuchKey|404" <<< "$output"; then
    if curl -fsI "$public_base/$1" > /dev/null 2>&1; then
      return 0
    fi
    return 1
  fi
  fail "cannot tell whether $bucket/$1 exists: $output"
}

keygen() {
  command -v op > /dev/null || fail "keygen needs the 1Password CLI (op)"
  if op item get "$signing_key_title" --vault "$signing_vault" > /dev/null 2>&1; then
    fail "1Password already has \"$signing_key_title\" in $signing_vault. Every installed stew trusts that key; delete the item yourself only if you mean to replace it."
  fi
  step "Building stew"
  swift build -c release > /dev/null
  local stew public_key_file
  stew="$(swift build -c release --show-bin-path)/stew"
  mkdir -p build
  public_key_file="$project_root/build/update-public-key.txt"
  rm -f "$public_key_file"
  step "Creating the key pair and storing the private key in 1Password ($signing_vault)"
  # The private key exists only in the pipe from stew to op: never on disk, never printed.
  if ! op item create --vault "$signing_vault" \
      --template <("$stew" _update-keygen --public-key-file "$public_key_file" --1password-title "$signing_key_title") \
      > /dev/null; then
    rm -f "$public_key_file"
    fail "op item create failed; no key was stored"
  fi
  [[ -s "$public_key_file" ]] || fail "no public key was written"
  echo
  echo "Stored \"$signing_key_title\" in the $signing_vault vault."
  echo "Public key: $(cat "$public_key_file")"
  echo
  echo "Paste it into Sources/stew/Updater.swift:"
  echo "    static let embeddedPublicKey = \"$(cat "$public_key_file")\""
  echo "then commit. Releases refuse to run while that constant is empty."
}

if [[ "$mode" == "keygen" ]]; then
  keygen
  exit 0
fi

version="$(tr -d '[:space:]' < VERSION)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "VERSION '$version' is not X.Y.Z"
build_number="$(git rev-list --count HEAD)"
readonly zip_name="Stew-$version.zip"
readonly zip_key="v$version/$zip_name"

step "stew $version (build $build_number), $mode"

if [[ "$mode" == "release" ]]; then
  [[ -z "$(git status --porcelain)" ]] || fail "the checkout has uncommitted changes; a release is built from a commit"
  [[ -n "$(embedded_public_key)" ]] || fail "Updater.embeddedPublicKey is empty. Run scripts/release.sh keygen first."
  for tool in xcrun op pnpm; do command -v "$tool" > /dev/null || fail "$tool is not installed"; done
  security find-identity -v -p codesigning | grep -qF "$sign_identity" || fail "no signing identity \"$sign_identity\" in the keychain"
  step "Checking that $zip_key is not published yet"
  if r2_exists "$zip_key"; then
    fail "$bucket/$zip_key already exists. Published versions never change; bump VERSION."
  fi
fi

step "Building a universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64 > /dev/null
binary="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/stew"
archs="$(lipo -archs "$binary")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$binary is not universal (it has: $archs)"

step "Assembling Stew.app"
rm -rf "$build_dir" "$dist_dir"
mkdir -p "$build_dir" "$dist_dir"
scripts/build-app.sh --binary "$binary" --out "$build_dir" --version "$version" --build "$build_number" > /dev/null
app="$build_dir/Stew.app"
stew="$app/Contents/MacOS/stew"

if [[ "$mode" == "release" ]]; then
  step "Signing with \"$sign_identity\" (hardened runtime, timestamp)"
  codesign --force --options runtime --timestamp --identifier nl.koode.stew --sign "$sign_identity" "$app"
else
  step "Signing ad hoc (dry run)"
  codesign --force --options runtime --timestamp=none --identifier nl.koode.stew --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"
if [[ "$mode" == "release" ]]; then
  team="$(codesign -dv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  [[ "$team" == "$team_id" ]] || fail "signed by team '$team', expected $team_id"

  step "Notarizing with profile \"$notary_profile\" (this can take a few minutes)"
  ditto -c -k --keepParent "$app" "$build_dir/notarize.zip"
  xcrun notarytool submit "$build_dir/notarize.zip" --keychain-profile "$notary_profile" --wait
  rm -f "$build_dir/notarize.zip"
  step "Stapling"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
else
  step "Skipping notarization (dry run)"
fi

step "Zipping $zip_name"
zip="$dist_dir/$zip_name"
ditto -c -k --keepParent "$app" "$zip"
sha256="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
size="$(stat -f%z "$zip")"

if [[ "$mode" == "release" ]]; then
  step "Signing the zip with the update key from 1Password"
  public_key="$(embedded_public_key)"
  # The private key goes from op straight into stew on stdin.
  signature="$(op read "$signing_key_ref" | "$stew" _sign-update "$zip")"
else
  step "Signing the zip with a throwaway update key (dry run)"
  throwaway_key="$("$stew" _update-keygen --public-key-file "$dist_dir/dry-run-public-key.txt")"
  public_key="$(cat "$dist_dir/dry-run-public-key.txt")"
  signature="$(printf '%s' "$throwaway_key" | "$stew" _sign-update "$zip")"
  unset throwaway_key
fi
"$stew" _verify-update "$zip" --signature "$signature" --public-key "$public_key" > /dev/null \
  || fail "the zip signature does not verify against the public key in this build"

step "Writing latest.json"
cat > "$dist_dir/latest.json" <<JSON
{
  "version": "$version",
  "build": $build_number,
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "minimumMacOS": "14.0",
  "notes": "https://stewcli.com/changelog#$version",
  "archive": {
    "url": "$public_base/$zip_key",
    "sha256": "$sha256",
    "size": $size,
    "ed25519": "$signature"
  }
}
JSON
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dist_dir/latest.json" || fail "latest.json is not valid JSON"
install -m 755 scripts/install-release.sh "$dist_dir/install.sh"

step "Writing the Homebrew cask"
scripts/render-cask.sh --version "$version" --sha256 "$sha256" --url "$public_base/$zip_key" --out "$dist_dir/stew.rb" > /dev/null
if command -v ruby > /dev/null; then
  ruby -c "$dist_dir/stew.rb" > /dev/null || fail "$dist_dir/stew.rb is not valid Ruby"
fi

if [[ "$mode" == "dry-run" ]]; then
  echo
  echo "Dry run done. Nothing was notarized or uploaded."
  echo "  $app"
  echo "  $zip ($size bytes, sha256 $sha256)"
  echo "  $dist_dir/latest.json"
  echo "  $dist_dir/install.sh"
  echo "  $dist_dir/stew.rb"
  echo "The throwaway public key is in $dist_dir/dry-run-public-key.txt."
  # The dry run's zip is ad hoc signed and not published, so its cask never goes to the tap.
  if [[ -n "$tap_dir" ]]; then
    echo "A real release would write the cask to $tap_dir/Casks/stew.rb."
  fi
  exit 0
fi

step "Publishing to $bucket"
# Checked again right before the upload, in case another run published meanwhile.
if r2_exists "$zip_key"; then
  fail "$bucket/$zip_key appeared while this release ran; not overwriting it"
fi
r2 put "$bucket/$zip_key" --file "$zip" --content-type "application/zip" \
  --cache-control "public, max-age=31536000, immutable" > /dev/null
echo "    $zip_key"
r2 put "$bucket/install.sh" --file "$dist_dir/install.sh" --content-type "text/plain; charset=utf-8" \
  --cache-control "public, max-age=300" > /dev/null
echo "    install.sh"
# Last, so it only ever points at a zip that is already there.
r2 put "$bucket/latest.json" --file "$dist_dir/latest.json" --content-type "application/json" \
  --cache-control "no-store" > /dev/null
echo "    latest.json"

# After the upload, so the tap never names a zip that is not published yet.
if [[ -n "$tap_dir" ]]; then
  mkdir -p "$tap_dir/Casks"
  install -m 644 "$dist_dir/stew.rb" "$tap_dir/Casks/stew.rb"
fi

echo
echo "Released stew $version (build $build_number):"
echo "  $public_base/$zip_key"
echo "  $public_base/latest.json"
echo "  $public_base/install.sh"
echo "Tag it: git tag v$version && git push origin v$version"
if [[ -n "$tap_dir" ]]; then
  echo "Wrote $tap_dir/Casks/stew.rb. Commit and push it in the tap:"
  echo "  git -C \"$tap_dir\" add Casks/stew.rb && git -C \"$tap_dir\" commit -m \"stew $version\" -- Casks/stew.rb && git -C \"$tap_dir\" push"
else
  echo "The Homebrew cask is in $dist_dir/stew.rb. Copy it to Casks/stew.rb in the koode/homebrew-apps tap"
  echo "and push it there, or run the next release with --tap-dir PATH to write it there."
fi
