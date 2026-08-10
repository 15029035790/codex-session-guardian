#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
destination=${1:-"$project_dir/dist/Codex-Session-Guardian.app"}
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/tokenpet-package.XXXXXX")
stage_app="$stage_root/Codex-Session-Guardian.app"

cleanup() {
    rm -rf "$stage_root"
}
trap cleanup EXIT

swift build --disable-sandbox --package-path "$project_dir"
mkdir -p "$stage_app/Contents/MacOS" "$stage_app/Contents/Resources"
cp "$project_dir/.build/arm64-apple-macosx/debug/CodexSessionGuardian" "$stage_app/Contents/MacOS/CodexSessionGuardian"
cp "$project_dir/Support/Info.plist" "$stage_app/Contents/Info.plist"
ditto "$project_dir/Sources/TokenPet/Resources/PetAnimations" "$stage_app/Contents/Resources/PetAnimations"
"$project_dir/scripts/build-app-icon.sh" "$stage_app/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$stage_app"
codesign --verify --deep --strict "$stage_app"
plutil -lint "$stage_app/Contents/Info.plist"

mkdir -p "${destination:h}"
ditto "$stage_app" "$destination"
codesign --verify --deep --strict "$destination"
print -r -- "$destination"
