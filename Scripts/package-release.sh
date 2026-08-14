#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
scratch_dir="${TMPDIR:-/tmp}/macbuddy-release-build"
staged_app="$scratch_dir/App/MacBuddy.app"
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/macbuddy-package.XXXXXX")
staging_dir="$package_dir/dmg-staging"

trap 'rm -rf "$package_dir"' EXIT

"$project_dir/Scripts/build-app.sh"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Support/Info.plist")
base_name="MacBuddy-$version-unsigned"
dmg_path="$dist_dir/$base_name.dmg"
zip_path="$dist_dir/$base_name.zip"
temporary_dmg="$package_dir/$base_name.dmg"
temporary_zip="$package_dir/$base_name.zip"

rm -rf "$dmg_path" "$zip_path" "$dist_dir/SHA256SUMS.txt"
mkdir -p "$staging_dir"
ditto "$staged_app" "$staging_dir/MacBuddy.app"
xattr -cr "$staging_dir/MacBuddy.app"
codesign --verify --deep --strict "$staging_dir/MacBuddy.app"
ln -s /Applications "$staging_dir/Applications"

hdiutil create \
  -volname "MacBuddy $version" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$temporary_dmg"

ditto -c -k --sequesterRsrc --keepParent "$staged_app" "$temporary_zip"
(
  cd "$package_dir"
  shasum -a 256 "$base_name.dmg" "$base_name.zip" > SHA256SUMS.txt
)

ditto "$temporary_dmg" "$dmg_path"
ditto "$temporary_zip" "$zip_path"
ditto "$package_dir/SHA256SUMS.txt" "$dist_dir/SHA256SUMS.txt"

echo "Packaged $dmg_path"
echo "Packaged $zip_path"
