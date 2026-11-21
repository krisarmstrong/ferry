#!/bin/bash
# Checks that the certificates a .p12 carried include a Developer ID Application identity:
# scripts/check-developer-id.sh <certificates.pem>
#
# Apple issues a Developer ID Installer certificate from the same page, and a .p12 exported from
# it opens and imports like the right one; the build then fails minutes later, saying only that
# the keychain has no Developer ID Application identity. This names what the .p12 holds instead,
# by each certificate's common name, which says nothing secret.
set -euo pipefail

pem="$1"
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
  name="$(/usr/bin/openssl x509 -in "$cert" -noout -subject -nameopt multiline \
    | sed -n 's/^ *commonName *= //p')"
  names+=("${name:-(no common name)}")
done

if [ "${#names[@]}" -eq 0 ]; then
  echo "::error::DEVELOPER_ID_P12_BASE64 holds no certificate"
  exit 1
fi
for name in "${names[@]}"; do
  if [[ "$name" == "Developer ID Application: "* ]]; then
    echo "Developer ID identity: $name"
    exit 0
  fi
done
held="$(printf '"%s", ' "${names[@]}")"
echo "::error::DEVELOPER_ID_P12_BASE64 holds no Developer ID Application certificate, only" \
  "${held%, }. Export the Developer ID Application identity (certificate and private key) as" \
  "the .p12 (see scripts/release-secrets.sh)."
exit 1
