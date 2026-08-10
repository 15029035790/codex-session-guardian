#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
destination=${1:-"$project_dir/.build/AppIcon.icns"}
source_image="$project_dir/Sources/TokenPet/Resources/PetAnimations/guardian/frame-00.png"
stage_root=$(mktemp -d "${TMPDIR:-/tmp}/tokenpet-icon.XXXXXX")
iconset="$stage_root/AppIcon.iconset"

cleanup() {
    rm -rf "$stage_root"
}
trap cleanup EXIT

mkdir -p "$iconset" "${destination:h}"
sips --cropToHeightWidth 82 82 --cropOffset 24 12 "$source_image" --out "$stage_root/guardian-square.png" >/dev/null

for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
    "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" "512 icon_256x256@2x" \
    "512 icon_512x512" "1024 icon_512x512@2x"
do
    pixels=${spec%% *}
    name=${spec#* }
    sips --resampleHeightWidth "$pixels" "$pixels" "$stage_root/guardian-square.png" \
        --out "$iconset/$name.png" >/dev/null
done

swift "$project_dir/scripts/make-icns.swift" "$iconset" "$destination"
