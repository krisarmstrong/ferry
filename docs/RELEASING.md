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
   its signature, both staples and Gatekeeper's verdict. Before it signs anything,
   `scripts/check-dmg-contents.sh` checks the image holds exactly the stapled app from the
   build job's `Ferry-X.Y.Z.zip`, file for file (type, mode, link target and SHA-256, with
   the same code directory hash and team), beside only the Applications link, the background
   and the layout, so the publish job never signs content the dmg job changed. CI builds and
   checks the image on every change, from the ad hoc release build, and
   `scripts/check-dmg-contents-test.sh` shows that check refusing a changed byte and an extra
   entry.

## What runs while the signing identity is usable

dmgbuild runs where no signing material is. Other third-party code does not, and that is a
known, accepted residual. In the build job, `make release` runs after the Developer ID identity
is imported into an unlocked keychain whose partition list lets `codesign` use it, so these run
while any code on the runner could sign with it:

- libusb's and libmtp's `configure` scripts and their builds (`scripts/build-libmtp.sh`);
- pkg-config, built from the pinned pkgconf source (`scripts/build-pkgconf.sh`);
- XcodeGen, from its pinned release zip;
- Xcode's package resolution of Sparkle and the framework's build phases.

Each is pinned: the tarballs and the XcodeGen zip by SHA-256, Sparkle by commit in
`project.yml` (whose `Package.swift` fixes the checksum SwiftPM checks the framework against).
What runs is what was reviewed when the pin changed; a change upstream fails the build rather
than running. The secrets live only in the `release` environment, which
deploys from `main` only. Moving these builds ahead of the keychain import would narrow the
window, but that path has never run a release, so it waits until it can be tried on a release
that is not V1.

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
that lasts longer. Each wait on a submission lasts at most 30 minutes, and one whose connection
drops is started again, so a slow notarization can take about 91 minutes before it fails as a
timeout; the build and publish jobs' timeouts (150 and 120 minutes) allow for that. A re-run
submits the file again, which is harmless: Apple gives the same bytes the same verdict. The pinned pkgconf comes from one host, distfiles.ariadne.space; if it is down,
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

## Losing a signing key

Two keys sign a release, and Sparkle checks both: an update installs if the archive's EdDSA
signature matches the `SUPublicEDKey` already in the installed app, **or** (when the EdDSA
signature fails) the new app is signed by the same Developer ID team as the installed one. So
one key can change at a time, never both in the same release. Rotate them one after the other,
and ship a release between.

Backups: the owner keeps the Sparkle private key (the output of `generate_keys -x`) and the
Developer ID `.p12` and the notary `.p8` offline, in at least two places. They are never in the
repository, a PR, an issue or a log. The Actions secrets (`SPARKLE_PRIVATE_KEY`,
`DEVELOPER_ID_P12_BASE64`, `NOTARY_*`) are a working copy, not a backup: GitHub never shows them
again.

### Lost, not leaked

Nothing is wrong yet for users: installed copies keep running and the feed keeps working. What
breaks is the next release.

- **Sparkle key lost, Developer ID intact.** Create a new key (`generate_keys`), put its public
  half in `project.yml` (`FERRY_SPARKLE_PUBLIC_KEY`) and the private half in the `release`
  environment secret `SPARKLE_PRIVATE_KEY` (`scripts/release-secrets.sh`). Ship the release
  through a PR as usual. It is signed with the new key, which installed copies reject, and so
  they fall back to the Developer ID check: same team, so it installs. From then on, copies
  that updated hold the new key.
- **Developer ID certificate lost or expired, Sparkle key intact.** Issue a new Developer ID
  Application certificate in the same Apple team, export a new `.p12`, update the `release`
  secrets, and ship. The team ID is unchanged, and the Sparkle signature still matches, so
  copies update. Notarization uses the App Store Connect key, a separate secret.
- **Both lost.** There is no automatic path. Copies cannot verify a new release by either
  check, so users must download the new `Ferry.dmg` from the release page once and replace the
  app. Say so in the release notes, and avoid this by keeping the backups above apart.

### Leaked, or suspected leaked

Rotate at once, and treat a leaked key as one an attacker can use to sign updates.

1. Remove the leaked secret from the `release` environment, and stop the release workflow
   running until the replacement is in place.
2. **Developer ID:** revoke the certificate at developer.apple.com, issue a new one in the same
   team, and update the secrets. **Sparkle:** do the rotation above.
3. Ship a fixed release signed with the new key. If both leaked, rotate them in two releases.
   Copies that installed an update built by an attacker are not recovered by this: say so
   in an advisory.
4. Publish a GitHub security advisory saying what leaked, the versions affected and that
   users should install the new release.

### Order, either way

1. Recover or issue the replacement key, and store its backup offline first.
2. Update `project.yml` (Sparkle public key, through a PR) and the `release` secrets.
3. Run a release (`docs/RELEASING.md`, Each release) and check the build job's signing step.
4. Install the previous release, check for updates, and confirm it offers and installs the new
   one. Only then rotate the second key, if it too has to change.
