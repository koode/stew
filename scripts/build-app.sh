#!/usr/bin/env bash
# Assembles Stew.app around a built stew binary. It does not compile or sign.
#
#   scripts/build-app.sh --binary PATH --out DIR [--version X.Y.Z] [--build N]
#
# Writes DIR/Stew.app, replacing an earlier one. The version defaults to the
# VERSION file. The build number defaults to the commit count of HEAD
# (git rev-list --count HEAD): main is kept linear, so it only grows, and the
# updater uses it to order two builds of the same version.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
binary=""
out_dir=""
version=""
build=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary) binary="$2"; shift ;;
    --out) out_dir="$2"; shift ;;
    --version) version="$2"; shift ;;
    --build) build="$2"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-app: unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

fail() { echo "build-app: $*" >&2; exit 1; }
[[ -n "$binary" && -x "$binary" ]] || fail "--binary must point at a built stew executable"
[[ -n "$out_dir" ]] || fail "--out is required"
[[ -n "$version" ]] || version="$(tr -d '[:space:]' < "$project_root/VERSION")"
[[ -n "$build" ]] || build="$(git -C "$project_root" rev-list --count HEAD)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "version '$version' is not X.Y.Z"
[[ "$build" =~ ^[0-9]+$ ]] || fail "build '$build' is not a whole number"

app="$out_dir/Stew.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/stew"
chmod 755 "$app/Contents/MacOS/stew"
cp "$project_root/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# The installers copy the skill out of the app, and the uninstaller ships inside it,
# so an install from a release zip has both without the source repository.
mkdir -p "$app/Contents/Resources/skill"
cp "$project_root/skill/SKILL.md" "$app/Contents/Resources/skill/SKILL.md"
install -m 755 "$project_root/uninstall.sh" "$app/Contents/Resources/uninstall.sh"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>stew</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>nl.koode.stew</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Stew</string>
  <key>CFBundleDisplayName</key><string>Stew</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$build</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Koode. Elastic License 2.0.</string>
</dict>
</plist>
PLIST
plutil -lint -s "$app/Contents/Info.plist" || fail "Info.plist is not valid"
printf 'APPL????' > "$app/Contents/PkgInfo"
echo "$app ($version, build $build)"
