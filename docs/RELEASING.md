# Releasing Ferry

Releases come from release-please and `.github/workflows/release.yml`; nobody tags by hand.

1. Merge conventional commits to `main`. release-please keeps a release PR open with the next
   version (before 1.0: `feat` is minor, `fix` a patch) and the CHANGELOG.
2. Merge the release PR. release-please tags `vX.Y.Z` and creates the GitHub release as a
   **draft**.
3. The build job signs, notarizes and staples Ferry, attaches `Ferry-X.Y.Z.zip`,
   `Ferry-X.Y.Z.dmg` and `appcast.xml`, then publishes the release as the latest. Installed
   copies read `releases/latest/download/appcast.xml` and update within a day.

## When the build fails

The release stays a draft, so `releases/latest` still points at the previous release and no
installed Ferry sees a missing feed. Fix the cause on `main`, then re-run the failed workflow run
(**Re-run failed jobs**): it builds the same tag again.

## Rolling back

Sparkle never installs an older version over a newer one. To stop a bad release from being
offered, mark the previous release as the latest
(`gh release edit vPREVIOUS --latest`): copies that have not updated yet stop seeing the bad one.
Copies that already updated get the fix only from a newer release, so ship `vX.Y.Z+1`.
