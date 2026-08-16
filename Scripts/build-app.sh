#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
scratch_dir="${TMPDIR:-/tmp}/macbuddy-release-build"
app_dir="$dist_dir/MacBuddy.app"
staged_app="$scratch_dir/App/MacBuddy.app"

cd "$project_dir"
rm -rf "$scratch_dir" "$app_dir"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources" "$staged_app/Contents/Frameworks"

products_dir=$(swift build \
  -c release \
  --arch arm64 \
  --scratch-path "$scratch_dir" \
  --show-bin-path)

swift build \
  -c release \
  --arch arm64 \
  --scratch-path "$scratch_dir"

ditto "$products_dir/MacBuddy" "$staged_app/Contents/MacOS/MacBuddy"
ditto "$products_dir/MacBuddy_MacBuddy.bundle" "$staged_app/Contents/Resources/MacBuddy_MacBuddy.bundle"
ditto "$products_dir/Sparkle.framework" "$staged_app/Contents/Frameworks/Sparkle.framework"
ditto "$project_dir/Support/Info.plist" "$staged_app/Contents/Info.plist"
ditto "$project_dir/Support/MacBuddy.icns" "$staged_app/Contents/Resources/MacBuddy.icns"
ditto "$project_dir/ThirdPartyNotices/Sparkle-LICENSE.txt" "$staged_app/Contents/Resources/Sparkle-LICENSE.txt"

sparkle_framework="$staged_app/Contents/Frameworks/Sparkle.framework"
sparkle_version_dir="$sparkle_framework/Versions/B"

# MacBuddy is not sandboxed, so Sparkle's sandbox-only XPC services are not used.
rm -rf "$sparkle_version_dir/XPCServices"
rm -f "$sparkle_framework/XPCServices"

for framework_binary in \
  "$sparkle_version_dir/Sparkle" \
  "$sparkle_version_dir/Autoupdate" \
  "$sparkle_version_dir/Updater.app/Contents/MacOS/Updater"
do
  lipo "$framework_binary" -thin arm64 -output "$framework_binary.arm64"
  mv "$framework_binary.arm64" "$framework_binary"
  strip -x "$framework_binary"
done

strip -x "$staged_app/Contents/MacOS/MacBuddy"
install_name_tool -add_rpath @executable_path/../Frameworks "$staged_app/Contents/MacOS/MacBuddy"

xattr -cr "$staged_app"
codesign --force --sign - "$sparkle_version_dir/Autoupdate"
codesign --force --sign - "$sparkle_version_dir/Updater.app"
codesign --force --sign - "$sparkle_framework"
codesign --force --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

mkdir -p "$dist_dir"
ditto "$staged_app" "$app_dir"
xattr -cr "$app_dir"
codesign --verify --deep "$app_dir"

echo "Built $app_dir"
file "$staged_app/Contents/MacOS/MacBuddy"
