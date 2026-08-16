#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
dist_dir="$project_dir/dist"
scratch_dir="${TMPDIR:-/tmp}/macbuddy-release-build"
staged_app="$scratch_dir/App/MacBuddy.app"
package_dir=$(mktemp -d "${TMPDIR:-/tmp}/macbuddy-package.XXXXXX")
staging_dir="$package_dir/dmg-staging"
updates_dir="$package_dir/updates"

trap 'rm -rf "$package_dir"' EXIT

"$project_dir/Scripts/build-app.sh"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/Support/Info.plist")
base_name="MacBuddy-$version-arm64-unsigned"
dmg_path="$dist_dir/$base_name.dmg"
zip_path="$dist_dir/$base_name.zip"
appcast_path="$dist_dir/appcast.xml"
temporary_dmg="$package_dir/$base_name.dmg"
temporary_zip="$package_dir/$base_name.zip"
release_notes="$project_dir/ReleaseNotes/$version.md"
sparkle_generate_appcast="$scratch_dir/artifacts/sparkle/Sparkle/bin/generate_appcast"
sparkle_sign_update="$scratch_dir/artifacts/sparkle/Sparkle/bin/sign_update"

rm -rf "$dmg_path" "$zip_path" "$appcast_path" "$dist_dir/SHA256SUMS.txt"
mkdir -p "$staging_dir" "$updates_dir"
test -x "$sparkle_generate_appcast"
test -x "$sparkle_sign_update"
test -f "$release_notes"
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

ditto "$temporary_zip" "$updates_dir/$base_name.zip"
ditto "$release_notes" "$updates_dir/$base_name.md"
"$sparkle_generate_appcast" \
  --account com.jaeyong.macbuddy \
  --download-url-prefix "https://github.com/Jae-Park/MacBuddy/releases/download/v$version/" \
  --link "https://github.com/Jae-Park/MacBuddy/releases/tag/v$version" \
  --embed-release-notes \
  "$updates_dir"
ditto "$updates_dir/appcast.xml" "$package_dir/appcast.xml"

"$sparkle_sign_update" --account com.jaeyong.macbuddy --verify "$package_dir/appcast.xml"
archive_signature=$(xmllint --xpath \
  'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' \
  "$package_dir/appcast.xml")
test -n "$archive_signature"
"$sparkle_sign_update" \
  --account com.jaeyong.macbuddy \
  --verify \
  "$temporary_zip" \
  "$archive_signature"

(
  cd "$package_dir"
  shasum -a 256 "$base_name.dmg" "$base_name.zip" appcast.xml > SHA256SUMS.txt
)

ditto "$temporary_dmg" "$dmg_path"
ditto "$temporary_zip" "$zip_path"
ditto "$package_dir/appcast.xml" "$appcast_path"
ditto "$package_dir/SHA256SUMS.txt" "$dist_dir/SHA256SUMS.txt"

echo "Packaged $dmg_path"
echo "Packaged $zip_path"
echo "Generated $appcast_path"
