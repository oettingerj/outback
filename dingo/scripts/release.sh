#!/bin/zsh
# Builds a signed, notarized Dingo-<version>.dmg, tags dingo-v<version>, and attaches the dmg to a
# draft GitHub release. Review the draft on GitHub, then publish it.
#
# Usage: scripts/release.sh 0.2.0
#
# One-time setup: store notarization credentials in the keychain (uses an app-specific password
# from appleid.apple.com):
#   xcrun notarytool store-credentials irwin-notary --apple-id <apple id> --team-id CXWKXPU9U5
set -euo pipefail
cd "${0:A:h}/.."

app_name=Dingo
identity="Developer ID Application: Queue Music LLC (CXWKXPU9U5)"
notary_profile=irwin-notary

fail() { echo "$*" >&2; exit 1 }

version=${1:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || fail "Usage: scripts/release.sh <major.minor.patch>"
tag="${app_name:l}-v$version"

[[ $(git branch --show-current) == main ]] || fail "Release from main."
[[ -z $(git status --porcelain -- . ../eucalyptus) ]] || fail "$app_name or eucalyptus has uncommitted changes."
git fetch --quiet --tags origin
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && fail "Tag $tag already exists."
# The release build embeds the Google OAuth client; without it sign-in is broken.
grep -Eq '^GOOGLE_CLIENT_ID *= *[^ ]' App/Secrets.xcconfig 2>/dev/null ||
  fail "Fill in App/Secrets.xcconfig first (see App/Secrets.example.xcconfig)."

out=build/dist
rm -rf $out
xcodegen generate --quiet
# Notarization requires a secure timestamp on every signature.
xcodebuild -project $app_name.xcodeproj -scheme $app_name -configuration Release \
  -destination generic/platform=macOS -derivedDataPath $out/derived -quiet build \
  MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) \
  OTHER_CODE_SIGN_FLAGS=--timestamp

app=$out/derived/Build/Products/Release/$app_name.app
codesign --verify --deep --strict $app
signature=$(codesign -dvv $app 2>&1)
[[ $signature == *"Authority=Developer ID Application"* ]] || fail "$app_name.app is not signed with Developer ID."
[[ $signature == *"Timestamp="* ]] || fail "$app_name.app signature has no secure timestamp."

staging=$out/dmg
mkdir -p $staging
ditto $app $staging/$app_name.app
ln -s /Applications $staging/Applications
dmg=$out/$app_name-$version.dmg
hdiutil create -quiet -volname $app_name -srcfolder $staging -format UDZO -ov $dmg
codesign --sign $identity --timestamp $dmg

echo "Notarizing $dmg…"
result=$(xcrun notarytool submit $dmg --keychain-profile $notary_profile --wait --output-format json)
notary_status=$(print -r -- $result | plutil -extract status raw -o - -)
if [[ $notary_status != Accepted ]]; then
  submission=$(print -r -- $result | plutil -extract id raw -o - -)
  xcrun notarytool log $submission --keychain-profile $notary_profile >&2 || true
  fail "Notarization finished with status: $notary_status"
fi
xcrun stapler staple -q $dmg
spctl --assess --type open --context context:primary-signature --verbose $dmg

# Generated notes start at this app's previous release, not the other app's.
notes_args=()
if previous=$(git describe --tags --abbrev=0 --match "${app_name:l}-v*" HEAD 2>/dev/null); then
  notes_args=(--notes-start-tag $previous)
fi
git tag -a $tag -m "$app_name $version"
git push --quiet origin $tag
gh release create $tag $dmg --draft --title "$app_name $version" --generate-notes \
  $notes_args --notes "Requires macOS 26 or later."
