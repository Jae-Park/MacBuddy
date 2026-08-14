#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
sprite="$project_dir/Sources/MacBuddy/Assets/macbuddy-mint-frames-48.png"
source_png="$project_dir/Support/MacBuddy-icon.png"
icon_output="$project_dir/Support/MacBuddy.icns"
temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/macbuddy-icon.XXXXXX")
iconset_dir="$temp_dir/MacBuddy.iconset"

trap 'rm -rf "$temp_dir"' EXIT
mkdir -p "$iconset_dir"

xcrun swift "$project_dir/Scripts/render-icon.swift" "$sprite" "$source_png"

sips -z 16 16 "$source_png" --out "$iconset_dir/icon_16x16.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$source_png" --out "$iconset_dir/icon_32x32.png" >/dev/null
sips -z 64 64 "$source_png" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$source_png" --out "$iconset_dir/icon_128x128.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$source_png" --out "$iconset_dir/icon_256x256.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$source_png" --out "$iconset_dir/icon_512x512.png" >/dev/null
cp "$source_png" "$iconset_dir/icon_512x512@2x.png"

iconutil -c icns "$iconset_dir" -o "$icon_output"
echo "Built $icon_output"
