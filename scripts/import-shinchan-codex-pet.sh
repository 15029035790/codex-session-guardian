#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
destination="$project_dir/Sources/TokenPet/Resources/PetAnimations/shinchan-codex-v1"
source_url="https://raw.githubusercontent.com/legeling/awesome-codex-pet/main/pets/shinchan--chenxin-dlut/spritesheet.webp"
expected_sha256="7ab137c52b22e14108109e3b30d02b4644a74c68224ea40fb56050e9109ceec2"
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/shinchan-codex-pet.XXXXXX")

cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

command -v ffmpeg >/dev/null || { print -u2 "ffmpeg is required"; exit 1; }
curl -L --fail --silent --show-error -o "$work_dir/spritesheet.webp" "$source_url"
actual_sha256=$(shasum -a 256 "$work_dir/spritesheet.webp" | awk '{print $1}')
[[ "$actual_sha256" == "$expected_sha256" ]] || {
    print -u2 "unexpected spritesheet checksum: $actual_sha256"
    exit 1
}

# Local semantic state -> Codex v1 atlas row and populated frame count.
typeset -A rows counts
rows=(idle 7 working 6 multitask 0 thinking 8 success 4 guardian 3)
counts=(idle 6 working 6 multitask 6 thinking 6 success 5 guardian 4)

for state in idle working multitask thinking success guardian; do
    mkdir -p "$destination/$state"
    for ((frame = 0; frame < counts[$state]; frame++)); do
        ffmpeg -loglevel error -y -i "$work_dir/spritesheet.webp" \
            -vf "crop=192:208:$((frame * 192)):$((rows[$state] * 208)),scale=106:116:flags=neighbor" \
            -frames:v 1 "$destination/$state/$(printf 'frame-%02d.png' "$frame")"
    done
done

print -r -- "$destination"
