#!/bin/bash
# Proves the Release tags ruleset (scripts/repo-settings.sh) lets release-please tag releases.
# Run it yourself right after repo-settings.sh; it needs your gh login with the workflow scope.
#
# release-please tags each release with the workflow's GITHUB_TOKEN, which acts as the GitHub
# Actions app, the ruleset's only bypass. Whether GitHub applies that bypass to GITHUB_TOKEN on
# this user-owned repository cannot be read from the settings, so this tries it:
#   1. you (not a bypass actor) try to create a v* tag: the ruleset must refuse;
#   2. a throwaway workflow, pushed to a throwaway branch, creates and deletes the tag
#      v0.0.0-bypass-check with GITHUB_TOKEN: it must succeed;
#   3. the branch is deleted again. Nothing touches main.
# If step 2 fails, the fallback is to drop the `creation` rule from the ruleset in
# repo-settings.sh (and run it again): release tags can then be created by anyone with push
# access, but still never moved or deleted, and the release job checks each tag against its
# draft release before signing anything.
#
# Usage: scripts/verify-tag-bypass.sh
set -euo pipefail

repo=krisarmstrong/ferry
branch=bypass-check
tag=v0.0.0-bypass-check
workflow=.github/workflows/bypass-check.yml

main="$(gh api "repos/$repo/git/ref/heads/main" --jq .object.sha)"

if gh api -X POST "repos/$repo/git/refs" -f ref="refs/tags/$tag-owner" -f sha="$main" \
  > /dev/null 2>&1; then
  gh api -X DELETE "repos/$repo/git/refs/tags/$tag-owner" > /dev/null 2>&1 || true
  echo "FAIL: you could create $tag-owner; the ruleset is not enforced. Run repo-settings.sh." >&2
  exit 1
fi
echo "pass: the ruleset refuses a v* tag from you"

cleanup() {
  gh api -X DELETE "repos/$repo/git/refs/heads/$branch" > /dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup
gh api -X POST "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$main" > /dev/null

content="$(base64 << 'YAML' | tr -d '\n'
name: Tag bypass check
on:
  push:
    branches: [bypass-check]
permissions:
  contents: write
jobs:
  check:
    runs-on: ubuntu-24.04
    steps:
      - name: Create and delete a v* tag with GITHUB_TOKEN
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh api -X POST "repos/$GITHUB_REPOSITORY/git/refs" \
            -f ref=refs/tags/v0.0.0-bypass-check -f sha="$GITHUB_SHA" > /dev/null
          gh api -X DELETE "repos/$GITHUB_REPOSITORY/git/refs/tags/v0.0.0-bypass-check"
YAML
)"
commit="$(gh api -X PUT "repos/$repo/contents/$workflow" -f branch="$branch" \
  -f message="ci: check the release tag ruleset's bypass (throwaway)" -f content="$content" \
  --jq .commit.sha)"

# GitHub registers the run a few seconds after the push; wait up to two minutes for it.
run=""
for _ in $(seq 60); do
  run="$(gh run list --repo "$repo" --commit "$commit" --json databaseId --jq '.[0].databaseId')"
  [ -n "$run" ] && break
  sleep 2
done
[ -n "$run" ] || { echo "FAIL: no workflow run started for $commit" >&2; exit 1; }

if gh run watch "$run" --repo "$repo" --exit-status > /dev/null; then
  echo "pass: GITHUB_TOKEN created and deleted $tag; release-please can tag releases"
else
  gh api "repos/$repo/git/refs/tags/$tag" > /dev/null 2>&1 \
    && echo "note: $tag was created but not deleted; remove it after editing the ruleset" >&2
  echo "FAIL: GITHUB_TOKEN could not create or delete $tag (gh run view $run --log-failed)." >&2
  echo "Fallback: remove {\"type\": \"creation\"} from the ruleset in scripts/repo-settings.sh" >&2
  echo "and run it again." >&2
  exit 1
fi
