# Releasing Ferry

Releases come from release-please and `.github/workflows/release.yml`; nobody tags by hand.

## Once

1. `scripts/repo-settings.sh`: the `release` environment (deployments from `main` only, no
   required reviewers, so releases stay automatic), a ruleset that lets nobody move or delete a
   `v*` tag, and branch protection requiring the CI `check`. Tag creation stays open: a
   user-owned repo cannot name GitHub Actions as a ruleset bypass actor, so a `creation` rule
   would stop release-please too. The build checks each tag against its draft before signing.
2. `scripts/release-secrets.sh <developer-id.p12> <AuthKey_….p8>`: the signing, notarization and
   Sparkle secrets, in the `release` environment, and the Sparkle public key in `project.yml`
   (commit it through a PR).

The build job signs only when the tag is the draft release release-please just created, and
the tag's commit is on `main`.

## Each release

1. Merge conventional commits to `main`. release-please keeps a release PR open with the next
   version (before 1.0: `feat` is minor, `fix` a patch) and the CHANGELOG. The release job runs
   CI on the PR's branch by dispatch, and that run reports the required `check` on the PR's
   head commit, as a commit status and a check run. The PR's own pull_request run waits for
   approval (GitHub asks for it on any PR GITHUB_TOKEN opens); it need not be approved. If the
   PR shows no passing `check`, see below.
2. Merge the release PR. release-please tags `vX.Y.Z` and creates the GitHub release as a
   **draft**.
3. The build job signs, notarizes and staples Ferry; the publish job attaches
   `Ferry-X.Y.Z.zip`, `Ferry-X.Y.Z.dmg` and `appcast.xml`, then publishes the release as the
   latest. Installed
   copies read `releases/latest/download/appcast.xml` and update within a day.
   The DMG opens on a designed window (`Design/DMG`) with the app and a link to Applications.
   `scripts/make-dmg.sh` builds it with dmgbuild (wheels pinned by SHA-256 in
   `scripts/dmg-requirements.txt`). dmgbuild is third-party code, so it runs only in the `dmg`
   job, which has no secrets, on the stapled app the build job hands on; the `publish` job
   then signs, notarizes and staples the image, and `scripts/check-dmg.sh --release` checks
   its signature, both staples and Gatekeeper's verdict. CI builds and checks the image on
   every change, from the ad hoc release build.

## When the release PR shows no passing `check`

The dispatched CI run reports `check` on the commit it tested, and nothing else does. So:

**The dispatched run failed** (or was cancelled). It left `check` failed on the head commit,
and that blocks the merge. Approving and passing the PR's own pull_request run does not clear
it: GitHub requires every `check` of that name to pass. Re-run the dispatched run (Actions →
CI → the `workflow_dispatch` run → **Re-run all jobs**), or start a new one on the release
branch:

```sh
gh workflow run ci.yml --ref release-please--branches--main--components--ferry
```

**The head commit was never tested.** No dispatch covers a head that release-please did not
push: after **Update branch** on the PR (branch protection wants it up to date with `main`, and
main moved on with only `ci:`, `test:` or `docs:` commits, which change no release notes), or
after any other push to the branch. The PR then waits for `check` with nothing running. Start
CI on the branch with the same `gh workflow run` command.

## When the build fails

The release stays a draft, so `releases/latest` still points at the previous release and no
installed Ferry sees a missing feed. What to do depends on the cause.

**Transient** (the runner, Apple's notary service, the network): **Re-run failed jobs** on that
workflow run, within 30 days. It builds the same tag again. A connection to the notary service
that drops (`NSURLErrorDomain` -1005 or -1001) is already tried three times by
`scripts/notarize.sh`, during the upload and again while waiting, so a re-run is for an outage
that lasts longer. A submission with no verdict after 30 minutes fails as a timeout; a re-run
submits it again. The pinned pkgconf comes from one host, distfiles.ariadne.space; if it is down,
the install step fails, and a re-run once it is back is the fix.

**The wrong certificate**: the import step fails, naming what `DEVELOPER_ID_P12_BASE64` holds,
when it is not a Developer ID Application identity of the team in `project.yml` (a Developer ID
Installer certificate looks the same in Keychain Access), or when a certificate in it cannot be
read. Export the right one and run `scripts/release-secrets.sh` again, then
re-run the failed jobs: the secrets are read when the job runs.

**Anything in the code or the configuration** (a build error, a failed check, notarization
refusing the app): a re-run cannot help. It runs the workflow file of the original run and checks
out the tag, so a fix on `main` never reaches it, and the tag cannot be moved to the fix: the
`Release tags` ruleset forbids moving or deleting a `v*` tag, the owner included. Instead:

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
