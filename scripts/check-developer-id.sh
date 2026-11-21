#!/bin/bash
# Checks that the certificates a .p12 carried include a Developer ID Application identity of the
# release's team: scripts/check-developer-id.sh <certificates.pem> <team ID>
#
# Apple issues a Developer ID Installer certificate from the same page, and a .p12 exported from
# it opens and imports like the right one; the build then fails minutes later, saying only that
# the keychain has no Developer ID Application identity. This names what the .p12 holds instead,
# by each certificate's common name, which says nothing secret.
set -euo pipefail

pem="$1"
team="$2"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo "::error::not a team ID: $team"; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
awk -v dir="$work" '
  /-----BEGIN CERTIFICATE-----/ { file = sprintf("%s/%03d.pem", dir, ++count) }
  file { print > file }
  /-----END CERTIFICATE-----/ { close(file); file = "" }
' "$pem"

names=()
for cert in "$work"/*.pem; do
  [ -e "$cert" ] || break
  subject="$(/usr/bin/openssl x509 -in "$cert" -noout -subject -nameopt multiline 2> /dev/null)" \
    || { echo "::error::certificate $((${#names[@]} + 1)) in DEVELOPER_ID_P12_BASE64 cannot be" \
      "read; export the .p12 again (see scripts/release-secrets.sh)"; exit 1; }
  name="$(sed -n 's/^ *commonName *= //p' <<< "$subject")"
  names+=("${name:-(no common name)}")
done

if [ "${#names[@]}" -eq 0 ]; then
  echo "::error::DEVELOPER_ID_P12_BASE64 holds no certificate"
  exit 1
fi
for name in "${names[@]}"; do
  if [[ "$name" == "Developer ID Application: "*" ($team)" ]]; then
    echo "Developer ID identity: $name"
    exit 0
  fi
done
held="$(printf '"%s", ' "${names[@]}")"
echo "::error::DEVELOPER_ID_P12_BASE64 holds no Developer ID Application certificate of team" \
  "$team, only" \
  "${held%, }. Export the Developer ID Application identity (certificate and private key) as" \
  "the .p12 (see scripts/release-secrets.sh)."
exit 1
