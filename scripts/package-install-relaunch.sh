#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
version=$(plutil -extract CFBundleShortVersionString raw "$project_dir/Support/Info.plist")
release_dir="$project_dir/dist/v$version"
release_app="$release_dir/Codex-Session-Guardian.app"
installed_app="$project_dir/outputs/installed/Codex Session Guardian.app"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/codex-session-guardian-release.XXXXXX")
stage_app="$stage_root/Codex-Session-Guardian.app"

cleanup() {
    rm -rf "$stage_root"
}
trap cleanup EXIT

"$project_dir/scripts/package-app.sh" "$stage_app"

rm -rf "$release_app" "$installed_app"
mkdir -p "$release_dir" "${installed_app:h}"
ditto "$stage_app" "$release_app"
ditto "$stage_app" "$installed_app"

rm -f "$release_dir/Codex-Session-Guardian-macos-arm64.zip" \
    "$release_dir/Codex-Session-Guardian-macos-arm64.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$release_app" \
    "$release_dir/Codex-Session-Guardian-macos-arm64.zip"
shasum -a 256 "$release_dir/Codex-Session-Guardian-macos-arm64.zip" \
    > "$release_dir/Codex-Session-Guardian-macos-arm64.zip.sha256"

pkill -x CodexSessionGuardian 2>/dev/null || true
sleep 0.4
open -n "$installed_app"
print -r -- "$installed_app"
