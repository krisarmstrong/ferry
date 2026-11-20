#!/bin/bash
# The repository settings releases rely on. Run it yourself (it changes settings of
# krisarmstrong/ferry with your gh login); running it again sets the same values.
#
# 1. A `release` environment that only main and v* tags may deploy from. The release secrets
#    live there (scripts/release-secrets.sh), so no other branch or workflow can read them.
# 2. A ruleset on v* tags: once release-please has made one, nobody can move or delete it.
# 3. Branch protection on main: the CI `check` must pass, on an up-to-date branch.
#
# Usage: scripts/repo-settings.sh
set -euo pipefail

repo=krisarmstrong/ferry

gh api -X PUT "repos/$repo/environments/release" --input - > /dev/null << 'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
existing="$(gh api "repos/$repo/environments/release/deployment-branch-policies" \
  --jq '.branch_policies[] | "\(.type) \(.name)"')"
for policy in "branch main" "tag v*"; do
  grep -qxF "$policy" <<< "$existing" && continue
  gh api -X POST "repos/$repo/environments/release/deployment-branch-policies" \
    -f type="${policy%% *}" -f name="${policy#* }" > /dev/null
done
echo "release environment: deployments from main and v* tags only"

ruleset='{
  "name": "Release tags",
  "target": "tag",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/tags/v*"], "exclude": []}},
  "rules": [{"type": "deletion"}, {"type": "update"}, {"type": "non_fast_forward"}]
}'
id="$(gh api "repos/$repo/rulesets" --jq '.[] | select(.name == "Release tags") | .id')"
if [ -n "$id" ]; then
  gh api -X PUT "repos/$repo/rulesets/$id" --input - <<< "$ruleset" > /dev/null
else
  gh api -X POST "repos/$repo/rulesets" --input - <<< "$ruleset" > /dev/null
fi
echo "v* tags: no deletion, no update"

gh api -X PUT "repos/$repo/branches/main/protection" --input - > /dev/null << 'JSON'
{"required_status_checks": {"strict": true, "contexts": ["check"]},
 "enforce_admins": false, "required_pull_request_reviews": null, "restrictions": null}
JSON
echo "main: the check job must pass before a merge"
