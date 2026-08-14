#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
scratch_dir="${TMPDIR:-/tmp}/macbuddy-release-build"
products_dir="$scratch_dir/apple/Products/Release"
app_dir="$dist_dir/MacBuddy.app"
staged_app="$scratch_dir/App/MacBuddy.app"

cd "$project_dir"
rm -rf "$scratch_dir" "$app_dir"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"

swift build \
  -c release \
  --arch arm64 \
  --arch x86_64 \
  --scratch-path "$scratch_dir"

ditto "$products_dir/MacBuddy" "$staged_app/Contents/MacOS/MacBuddy"
ditto "$products_dir/MacBuddy_MacBuddy.bundle" "$staged_app/Contents/Resources/MacBuddy_MacBuddy.bundle"
ditto "$project_dir/Support/Info.plist" "$staged_app/Contents/Info.plist"
ditto "$project_dir/Support/MacBuddy.icns" "$staged_app/Contents/Resources/MacBuddy.icns"

xattr -cr "$staged_app"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

mkdir -p "$dist_dir"
ditto "$staged_app" "$app_dir"

echo "Built $app_dir"
file "$staged_app/Contents/MacOS/MacBuddy"
