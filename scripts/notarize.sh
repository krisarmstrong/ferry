#!/bin/bash
# Notarizes a file and waits for Apple's verdict: scripts/notarize.sh <file>
#
# The notary service drops a connection now and then (NSURLErrorDomain -1005, the network
# connection was lost, or -1001, timed out), and one such drop failed a release that had
# nothing wrong with it. A drop is tried again, three attempts in all, 30 s and then 60 s apart.
# Once Apple has given the submission an id, the next attempt waits on that submission rather
# than uploading the file again. A verdict is final: anything but Accepted (Invalid, Rejected)
# prints the submission's log and fails, and is never retried.
#
# Takes the API key from NOTARY_KEY (the .p8 file's path), NOTARY_KEY_ID and NOTARY_ISSUER_ID.
set -euo pipefail

file="$1"
auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
attempts=3
delays=(30 60)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
id=""

for ((attempt = 1; attempt <= attempts; attempt++)); do
  if [ -n "$id" ]; then
    command=(xcrun notarytool wait "$id")
  else
    command=(xcrun notarytool submit "$file" --wait)
  fi
  status=0
  "${command[@]}" "${auth[@]}" --output-format json > "$work/out" 2> "$work/err" || status=$?
  verdict="$(jq -r '.status // empty' "$work/out" 2> /dev/null || true)"
  printed="$(jq -r '.id // empty' "$work/out" 2> /dev/null || true)"
  if [ -z "$printed" ]; then
    printed="$(grep -Eoh '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
      "$work/out" "$work/err" | head -1 || true)"
  fi
  [ -n "$printed" ] && id="$printed"

  if [ "$verdict" = Accepted ]; then
    echo "notarization of $file accepted (submission $id)"
    exit 0
  fi
  if [ -n "$verdict" ]; then
    [ -n "$id" ] && xcrun notarytool log "$id" "${auth[@]}"
    echo "::error::notarization of $file was not accepted: $(cat "$work/out")"
    exit 1
  fi
  cat "$work/err" >&2
  if ! grep -Eq 'NSURLErrorDomain Code=-(1005|1001)[^0-9]' "$work/err" "$work/out"; then
    echo "::error::notarytool failed for $file (exit $status)"
    exit 1
  fi
  if ((attempt == attempts)); then
    echo "::error::notarytool lost its connection to Apple on all $attempts attempts for $file"
    exit 1
  fi
  delay="${delays[attempt - 1]}"
  echo "::warning::notarytool lost its connection to Apple (attempt $attempt of $attempts);" \
    "trying again in ${delay}s${id:+, waiting on submission $id}"
  sleep "$delay"
done
