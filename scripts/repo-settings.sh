#!/bin/bash
# The repository settings releases rely on. Run it yourself (it changes settings of
# krisarmstrong/ferry with your gh login); running it again sets the same values.
#
# 1. A `release` environment that only the main branch may deploy from. The release secrets
#    live there (scripts/release-secrets.sh). The release job runs from the push to main that
#    created the release, so its ref is main; no tag and no other branch can reach the secrets.
#    There are no required reviewers: releases are fully automatic, by the owner's choice. The
#    cost is that whatever lands on main is signed and shipped without a human approving the
#    release run. Branch protection (3) stops others from merging without CI, but not you: it
#    does not bind admins (enforce_admins is false), and you are the only admin, so merging a
#    PR into main is itself the decision to ship.
# 2. A ruleset on v* tags: nobody creates, moves or deletes one except GitHub Actions, through
#    which release-please tags each release. GitHub cannot narrow that bypass to one workflow:
#    any workflow with contents: write could create a v* tag, but such a tag never reaches the
#    secrets (1), and the release job also checks the tag is release-please's draft on main.
# 3. Branch protection on main: the CI `check` must pass, on an up-to-date branch, and it must
#    come from GitHub Actions: a status named `check` posted by anything else does not count.
#
# Then run scripts/verify-tag-bypass.sh: it proves the bypass in (2) applies to release-please.
#
# Usage: scripts/repo-settings.sh
set -euo pipefail

repo=krisarmstrong/ferry
# The GitHub Actions app, whose GITHUB_TOKEN release-please uses.
actions_app_id=15368

gh api -X PUT "repos/$repo/environments/release" --input - > /dev/null << 'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
policies="$(gh api "repos/$repo/environments/release/deployment-branch-policies" \
  --jq '.branch_policies[] | "\(.id) \(.type) \(.name)"')"
main_allowed=no
while read -r id type name; do
  [ -n "$id" ] || continue
  if [ "$type" = branch ] && [ "$name" = main ]; then
    main_allowed=yes
  else
    gh api -X DELETE "repos/$repo/environments/release/deployment-branch-policies/$id"
    echo "removed the release environment's $type policy $name"
  fi
done <<< "$policies"
if [ "$main_allowed" = no ]; then
  gh api -X POST "repos/$repo/environments/release/deployment-branch-policies" \
    -f type=branch -f name=main > /dev/null
fi
echo "release environment: deployments from main only, no required reviewers"

ruleset="{
  \"name\": \"Release tags\",
  \"target\": \"tag\",
  \"enforcement\": \"active\",
  \"conditions\": {\"ref_name\": {\"include\": [\"refs/tags/v*\"], \"exclude\": []}},
  \"rules\": [{\"type\": \"creation\"}, {\"type\": \"update\"}, {\"type\": \"deletion\"},
    {\"type\": \"non_fast_forward\"}],
  \"bypass_actors\": [{\"actor_id\": $actions_app_id, \"actor_type\": \"Integration\",
    \"bypass_mode\": \"always\"}]
}"
id="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "Release tags") | .id')"
if [ -n "$id" ]; then
  gh api -X PUT "repos/$repo/rulesets/$id" --input - <<< "$ruleset" > /dev/null
else
  gh api -X POST "repos/$repo/rulesets" --input - <<< "$ruleset" > /dev/null
fi
echo "v* tags: created only by GitHub Actions; never updated or deleted"

gh api -X PUT "repos/$repo/branches/main/protection" --input - > /dev/null << JSON
{"required_status_checks": {"strict": true,
   "checks": [{"context": "check", "app_id": $actions_app_id}]},
 "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null}
JSON
echo "main: GitHub Actions' check job must pass before a merge (admins excepted)"
