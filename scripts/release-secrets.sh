#!/bin/bash
# Sets up everything a release needs that only the owner may handle. Run it yourself, in
# Terminal, from the repository; it asks for each password and prints none of them.
#
#   1. Export the Developer ID certificate first, in Keychain Access: My Certificates, select
#      "Developer ID Application: Kris Armstrong (X6JWYP43HG)" (one row, with its key), File >
#      Export Items…, save as .p12 with a new password. `security export` cannot pick one
#      identity, and exporting them all would put every signing key you have into GitHub.
#   2. Create an App Store Connect API key for notarization (App Store Connect > Users and
#      Access > Integrations > Team Keys, access Developer) and download its .p8 once.
#
# Usage: scripts/release-secrets.sh <developer-id.p12> <AuthKey_XXXXXXXXXX.p8>
# Then: commit the public key it writes into project.yml, delete the .p12 and keep the .p8 safe.
set -euo pipefail
cd "$(dirname "$0")/.."

repo=krisarmstrong/ferry
p12="$1"
p8="$2"
sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
# Sparkle keeps the private key in your login keychain under this account.
sparkle_account=io.github.krisarmstrong.ferry

# Developer ID certificate and key, for signing in the release workflow.
read -r -s -p "Password of $p12: " p12_password
echo
base64 < "$p12" | gh secret set DEVELOPER_ID_P12_BASE64 --repo "$repo"
printf '%s' "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo"
unset p12_password

# App Store Connect API key, for notarytool: in GitHub, and in your keychain as the
# "ferry-notary" profile for notarizing by hand (xcrun notarytool ... --keychain-profile).
read -r -p "Key ID of $p8 (10 characters): " key_id
read -r -p "Issuer ID (App Store Connect > Integrations, above the keys): " issuer_id
printf '%s' "$key_id" | gh secret set NOTARY_KEY_ID --repo "$repo"
printf '%s' "$issuer_id" | gh secret set NOTARY_ISSUER_ID --repo "$repo"
gh secret set NOTARY_KEY_P8 --repo "$repo" < "$p8"
xcrun notarytool store-credentials ferry-notary --key "$p8" --key-id "$key_id" \
  --issuer "$issuer_id"

# Sparkle's EdDSA key: made once with Sparkle's generate_keys, kept in your login keychain, its
# private half in GitHub, its public half in every Ferry.
tools="$(mktemp -d)"
trap 'rm -r "$tools"' EXIT
curl -fsSL -o "$tools/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
echo "$sparkle_sha256  $tools/sparkle.tar.xz" | shasum -a 256 -c --status \
  || { echo "error: Sparkle's tools do not match their pinned SHA-256" >&2; exit 1; }
tar -xJf "$tools/sparkle.tar.xz" -C "$tools"
"$tools/bin/generate_keys" --account "$sparkle_account" > /dev/null
"$tools/bin/generate_keys" --account "$sparkle_account" -x "$tools/sparkle-private-key"
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" < "$tools/sparkle-private-key"
public_key="$("$tools/bin/generate_keys" --account "$sparkle_account" -p)"
PUBLIC_KEY="$public_key" perl -pi -e \
  's/^(    FERRY_SPARKLE_PUBLIC_KEY: )FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER$/$1$ENV{PUBLIC_KEY}/' \
  project.yml

gh secret list --repo "$repo"
echo
echo "Sparkle public key: $public_key (now in project.yml; commit it on a branch and open a PR)."
echo "Back up the private key: Keychain Access, login keychain, \"Private key for signing Sparkle updates\""
echo "(account $sparkle_account). Losing it means no installed Ferry can update again."
