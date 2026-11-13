#!/usr/bin/env bash
# Writes the Homebrew cask for one release from packaging/homebrew/stew.rb.template.
#
#   scripts/render-cask.sh --version X.Y.Z --sha256 HEX --url URL --out FILE
#
# The URL must name the version; in the cask it becomes "#{version}", so the next
# release only changes the version and sha256 lines. scripts/release.sh runs this; the
# result goes to Casks/stew.rb in the koode/homebrew-apps tap.
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
template="$project_root/packaging/homebrew/stew.rb.template"
version=""
sha256=""
url=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) version="$2"; shift ;;
    --sha256) sha256="$2"; shift ;;
    --url) url="$2"; shift ;;
    --out) out="$2"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "render-cask: unknown option: $1" >&2; exit 64 ;;
  esac
  shift
done

fail() { echo "render-cask: $*" >&2; exit 1; }
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail "--version '$version' is not X.Y.Z"
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || fail "--sha256 must be 64 lowercase hex characters"
[[ "$url" == https://* ]] || fail "--url must be https"
[[ "$url" == *"$version"* ]] || fail "--url must contain the version $version"
[[ -n "$out" ]] || fail "--out is required"

version_reference='#{version}'
cask_url="${url//"$version"/$version_reference}"
mkdir -p "$(dirname "$out")"
sed -e "s|@VERSION@|$version|" -e "s|@SHA256@|$sha256|" -e "s|@URL@|$cask_url|" "$template" > "$out"
if grep -q '@[A-Z0-9]*@' "$out"; then
  fail "$out still has a placeholder: $(grep -o '@[A-Z0-9]*@' "$out" | head -1)"
fi
echo "$out"
