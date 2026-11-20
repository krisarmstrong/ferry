# Releasing Ferry

Releases come from release-please and `.github/workflows/release.yml`; nobody tags by hand.

## Once

1. `scripts/repo-settings.sh`: the `release` environment (deployments from `main` only, no
   required reviewers, so releases stay automatic), a ruleset that lets only GitHub Actions
   create `v*` tags and nobody move or delete them, and branch protection requiring the CI
   `check`.
2. `scripts/release-secrets.sh <developer-id.p12> <AuthKey_….p8>`: the signing, notarization and
   Sparkle secrets, in the `release` environment, and the Sparkle public key in `project.yml`
   (commit it through a PR).

The build job signs only when the tag is the draft release release-please just created, and
the tag's commit is on `main`.

## Each release

1. Merge conventional commits to `main`. release-please keeps a release PR open with the next
   version (before 1.0: `feat` is minor, `fix` a patch) and the CHANGELOG.
2. Merge the release PR. release-please tags `vX.Y.Z` and creates the GitHub release as a
   **draft**.
3. The build job signs, notarizes and staples Ferry, attaches `Ferry-X.Y.Z.zip`,
   `Ferry-X.Y.Z.dmg` and `appcast.xml`, then publishes the release as the latest. Installed
   copies read `releases/latest/download/appcast.xml` and update within a day.

## When the build fails

The release stays a draft, so `releases/latest` still points at the previous release and no
installed Ferry sees a missing feed. What to do depends on the cause.

**Transient** (the runner, Apple's notary service, the network): **Re-run failed jobs** on that
workflow run, within 30 days. It builds the same tag again.

**Anything in the code or the configuration** (a build error, a failed check, notarization
refusing the app): a re-run cannot help. It runs the workflow file of the original run and checks
out the tag, so a fix on `main` never reaches it, and the tag cannot be moved to the fix: the
`Release tags` ruleset forbids moving or deleting a `v*` tag, the owner included (only GitHub
Actions bypasses it). Instead:

1. Land the fix on `main` as a conventional commit (`fix: …`).
2. Delete the stale draft (`gh release delete vX.Y.Z`; it is a draft, so nobody saw it).
3. Let release-please cut the next version. The merged release PR already recorded `X.Y.Z` in
   `.release-please-manifest.json` and the tag exists, so its next release PR is `X.Y.Z+1`.
   Merge that.

The orphaned `vX.Y.Z` tag stays, which is harmless: no release names it. Removing it means
editing the ruleset for a moment.

## Rolling back

Sparkle never installs an older version over a newer one. To stop a bad release from being
offered, mark the previous release as the latest
(`gh release edit vPREVIOUS --latest`): copies that have not updated yet stop seeing the bad one.
Copies that already updated get the fix only from a newer release, so ship `vX.Y.Z+1`.
