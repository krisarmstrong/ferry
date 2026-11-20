#!/bin/bash
# Sets up everything a release needs that only the owner may handle. Run it yourself, in
# Terminal, from the repository; it asks for each password and prints none of them.
#
#   0. Run scripts/repo-settings.sh first: the secrets go into its `release` environment.
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
# The exported private key file is readable by you alone.
umask 077
cd "$(dirname "$0")/.."

repo=krisarmstrong/ferry
names=(DEVELOPER_ID_P12_BASE64 DEVELOPER_ID_P12_PASSWORD NOTARY_KEY_ID NOTARY_ISSUER_ID
  NOTARY_KEY_P8 SPARKLE_PRIVATE_KEY)

# Only the release environment may hold the release secrets: a repository secret of the same
# name would reach every workflow on every branch. Removes any, then makes sure none is left.
# Runs first on every run, and alone with --cleanup-only.
remove_repository_copies() {
  local name repository_secrets
  for name in "${names[@]}"; do
    gh secret delete "$name" --repo "$repo" 2> /dev/null || true
  done
  repository_secrets="$(gh secret list --repo "$repo" --json name --jq '.[].name')"
  for name in "${names[@]}"; do
    if grep -qxF "$name" <<< "$repository_secrets"; then
      echo "error: $name is still a repository secret; delete it in the repository's settings" >&2
      exit 1
    fi
  done
  echo "No release secret is stored at repository level. If one ever was, rotate that key or"
  echo "certificate: any workflow on any branch could have read it."
}

if [ "${1:-}" = --cleanup-only ] && [ "$#" -eq 1 ]; then
  remove_repository_copies
  exit 0
fi
if [ "$#" -ne 2 ] || [ ! -f "$1" ] || [ ! -f "$2" ]; then
  echo "usage: $0 <developer-id.p12> <AuthKey_XXXXXXXXXX.p8>  (both files must exist)" >&2
  echo "       $0 --cleanup-only   (only remove repository-level copies of the secrets)" >&2
  exit 2
fi

# The secrets go only into a release environment that main alone may deploy from
# (scripts/repo-settings.sh). A release run on main before that script ran would have created
# the environment with no policy, open to every branch.
environment="$(gh api "repos/$repo/environments/release" \
  --jq '"\(.deployment_branch_policy.protected_branches) \(.deployment_branch_policy.custom_branch_policies)"' \
  2> /dev/null)" || environment=""
policies="$(gh api "repos/$repo/environments/release/deployment-branch-policies" \
  --jq '[.branch_policies[] | "\(.type) \(.name)"] | join(",")' 2> /dev/null)" || policies=""
if [ "$environment" != "false true" ] || [ "$policies" != "branch main" ]; then
  echo "error: the release environment must exist and admit only the main branch" >&2
  echo "(found: ${environment:-no environment}; policies: ${policies:-none})." >&2
  echo "Run scripts/repo-settings.sh first." >&2
  exit 1
fi

remove_repository_copies

grep -q '^      FERRY_SPARKLE_PUBLIC_KEY: FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER$' project.yml || {
  echo "error: project.yml no longer has the key placeholder; the Sparkle key is already set" >&2
  exit 1
}

p12="$1"
p8="$2"
sparkle_version=2.10.1
sparkle_sha256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
# Sparkle keeps the private key in your login keychain under this account.
sparkle_account=io.github.krisarmstrong.ferry

# Developer ID certificate and key, for signing in the release workflow.
read -r -s -p "Password of $p12: " p12_password
echo
base64 < "$p12" | gh secret set DEVELOPER_ID_P12_BASE64 --repo "$repo" --env release
printf '%s' "$p12_password" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$repo" --env release
unset p12_password

# App Store Connect API key, for notarytool: in GitHub, and in your keychain as the
# "ferry-notary" profile for notarizing by hand (xcrun notarytool ... --keychain-profile).
read -r -p "Key ID of $p8 (10 characters): " key_id
read -r -p "Issuer ID (App Store Connect > Integrations, above the keys): " issuer_id
printf '%s' "$key_id" | gh secret set NOTARY_KEY_ID --repo "$repo" --env release
printf '%s' "$issuer_id" | gh secret set NOTARY_ISSUER_ID --repo "$repo" --env release
gh secret set NOTARY_KEY_P8 --repo "$repo" --env release < "$p8"
xcrun notarytool store-credentials ferry-notary --key "$p8" --key-id "$key_id" \
  --issuer "$issuer_id"

# Sparkle's EdDSA key: made once with Sparkle's generate_keys, kept in your login keychain, its
# private half in GitHub, its public half in every Ferry.
tools="$(mktemp -d)"
trap 'rm -rf "$tools"' EXIT
curl -fsSL -o "$tools/sparkle.tar.xz" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz"
echo "$sparkle_sha256  $tools/sparkle.tar.xz" | shasum -a 256 -c --status \
  || { echo "error: Sparkle's tools do not match their pinned SHA-256" >&2; exit 1; }
tar -xJf "$tools/sparkle.tar.xz" -C "$tools"
"$tools/bin/generate_keys" --account "$sparkle_account" > /dev/null
"$tools/bin/generate_keys" --account "$sparkle_account" -x "$tools/sparkle-private-key"
gh secret set SPARKLE_PRIVATE_KEY --repo "$repo" --env release < "$tools/sparkle-private-key"
public_key="$("$tools/bin/generate_keys" --account "$sparkle_account" -p)"
PUBLIC_KEY="$public_key" perl -pi -e \
  's/^(      FERRY_SPARKLE_PUBLIC_KEY: )FERRY_SPARKLE_PUBLIC_KEY_PLACEHOLDER$/$1$ENV{PUBLIC_KEY}/' \
  project.yml
grep -qxF "      FERRY_SPARKLE_PUBLIC_KEY: $public_key" project.yml || {
  echo "error: the public key did not reach project.yml; set FERRY_SPARKLE_PUBLIC_KEY to" >&2
  echo "$public_key by hand" >&2
  exit 1
}

gh secret list --repo "$repo" --env release

echo
echo "Sparkle public key: $public_key (now in project.yml; commit it on a branch and open a PR)."
echo "Back up the private key: Keychain Access, login keychain, \"Private key for signing Sparkle updates\""
echo "(account $sparkle_account). Losing it means no installed Ferry can update again."
