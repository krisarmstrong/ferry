#!/bin/bash
# Notarizes a file and waits for Apple's verdict: scripts/notarize.sh <file>
#
# Two steps. `submit` without `--wait` returns once the upload has succeeded, with the
# submission's id; `wait` then polls that submission for at most 30 minutes. The notary service
# drops a connection now and then (NSURLErrorDomain -1005, the network connection was lost, or
# -1001, timed out), and one such drop failed a release that had nothing wrong with it. Each step
# tries a drop again, three attempts in all, 30 s and then 60 s apart: a failed upload is
# uploaded again (json output names no id until it is done), and a dropped wait waits on the same
# submission, so a file Apple has is never sent twice. Accepted passes; Invalid or Rejected
# prints the submission's log and fails, never retried; a wait that ends with no verdict fails
# as a timeout.
#
# Takes the API key from NOTARY_KEY (the .p8 file's path), NOTARY_KEY_ID and NOTARY_ISSUER_ID.
# The two identifiers reach notarytool's argv, where `ps` on the runner can see them: they are
# not key material, and notarytool takes them no other way.
set -euo pipefail

file="$1"
auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
limit=30m
delays=(30 60)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Runs notarytool with `$@`, retrying a dropped connection. Leaves the last attempt's output in
# $work/out and returns its exit status; `what` names the step in messages.
notarytool_retrying() {
  local what="$1" attempt status
  shift
  for attempt in 1 2 3; do
    status=0
    xcrun notarytool "$@" "${auth[@]}" --output-format json > "$work/out" 2> "$work/err" \
      || status=$?
    [ "$status" -eq 0 ] && return 0
    cat "$work/err" >&2
    grep -Eq 'NSURLErrorDomain Code=-(1005|1001)[^0-9]' "$work/err" "$work/out" || return "$status"
    if [ "$attempt" -eq 3 ]; then
      echo "::error::$what lost its connection to Apple 3 times"
      exit 1
    fi
    echo "::warning::$what lost its connection to Apple (attempt $attempt of 3);" \
      "trying again in ${delays[attempt - 1]}s"
    sleep "${delays[attempt - 1]}"
  done
}

json() { jq -r "$1 // empty" "$work/out" 2> /dev/null || true; }

notarytool_retrying "uploading $file" submit "$file" \
  || { echo "::error::notarytool could not upload $file"; exit 1; }
id="$(json .id)"
[[ "$id" =~ ^[0-9a-f-]{36}$ ]] \
  || { echo "::error::notarytool gave no submission id for $file: $(cat "$work/out")"; exit 1; }

notarytool_retrying "waiting on submission $id" wait "$id" --timeout "$limit" || true
verdict="$(json .status)"
case "$verdict" in
  Accepted)
    echo "notarization of $file accepted (submission $id)"
    ;;
  Invalid | Rejected)
    echo "::error::notarization of $file was not accepted: $(cat "$work/out")"
    xcrun notarytool log "$id" "${auth[@]}" || true
    exit 1
    ;;
  *)
    echo "::error::submission $id had no verdict within $limit (${verdict:-no status}):" \
      "$(cat "$work/err")"
    exit 1
    ;;
esac
