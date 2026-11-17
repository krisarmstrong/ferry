# Spike: FileProvider, XPC and signing (Plan 2, Task 0)

Date: 2026-11-17. macOS 27.2, Xcode 27.2, XcodeGen 2.46.0, deployment target macOS 26.
Throwaway code was in `spikes/fileprovider/` (deleted). Layout matched the spec: `Ferry.app`
with the agent at `Contents/MacOS/FerryAgent` (a `tool` target with an embedded Info.plist),
its launchd plist in `Contents/Library/LaunchAgents/` (`BundleProgram`, `MachServices`), and
`FerryProvider.appex` (sandboxed `NSFileProviderReplicatedExtension`) in `Contents/PlugIns/`.

## Identifiers used

| Thing | Value |
|---|---|
| Team | `X6JWYP43HG` |
| App | `io.github.krisarmstrong.ferry` (unsandboxed, app group) |
| Agent | `io.github.krisarmstrong.ferry.agent` (unsandboxed, app group) |
| Extension | `io.github.krisarmstrong.ferry.provider` (sandbox + app group) |
| App group | `X6JWYP43HG.io.github.krisarmstrong.ferry` (also `NSExtensionFileProviderDocumentGroup`) |
| Mach service | `X6JWYP43HG.io.github.krisarmstrong.ferry.agent` |

## Results

| Assumption | Result | Evidence |
|---|---|---|
| `xcodebuild -allowProvisioningUpdates` with Automatic style and "Apple Development" signs all three targets | **Yes, without any provisioning profile.** No profile was created or needed: the team-prefixed app group is not a profile-gated entitlement on macOS. Xcode's empty account list did not block the build. | `** BUILD SUCCEEDED **`; build log `PROVISIONING_PROFILE_REQUIRED=NO`; no `embedded.provisionprofile` in app or appex; profile dir still 13 files, none for `io.github.krisarmstrong.ferry`. `codesign -dvv`: `Authority=Apple Development: Kris Armstrong (D6TYZMJE48)`, `TeamIdentifier=X6JWYP43HG` on app, agent and appex. `codesign --verify --deep --strict`: valid. |
| Automatic provisioning creates a profile with App Groups + FileProvider | **Not exercised** (nothing required a profile, so Xcode never contacted the portal). Developer ID signing was not exercised either. | as above |
| `SMAppService.agent(plistName:)` registers the bundled agent | **Yes**, enabled immediately, no approval step. macOS showed the "App Background Activity: Ferry can run in the background" notification. | `status=3` (notFound) → `register ok, status=1` (enabled). `launchctl print gui/501/io.github.krisarmstrong.ferry.agent`: `program identifier = Contents/MacOS/FerryAgent`, Mach service `X6JWYP43HG.io.github.krisarmstrong.ferry.agent`. |
| Agent vends `NSXPCListener(machServiceName:)`; launchd starts it on demand | **Yes** (from the app). | `FerryAgent[73717] agent started ... bundleID=io.github.krisarmstrong.ferry.agent bundlePath=.../Ferry.app`; `app got: pong from agent pid 73717 to 'hello from app'`. |
| Sandboxed extension can look up the team-prefixed Mach service and ping | **Not verified.** The extension never launched, because new domains are user-disabled (next rows). No Sandbox denial for Ferry was logged. | `log show --predicate 'sender == "Sandbox"'`: no `ferry` denials; no `extension init` line. |
| The **agent** may call `NSFileProviderManager.add(_:)` | **Yes.** The domain is attributed to the app's provider (`containing bundle identifier: io.github.krisarmstrong.ferry`) and is visible to the app's `getDomains`. The app can add domains too. | `agent add(agent): ok`; app `domains: ["agent userEnabled=false ...", "app userEnabled=false ..."]`; fileproviderd `extension session ... io.github.krisarmstrong.ferry.provider/agent initialized`; `getUserVisibleURL` → `~/Library/CloudStorage/Ferry-FerrySpikeagent`. |
| A new domain is live and its enumerator is called | **No, until the user enables Ferry.** Every new domain is created `userEnabled=false`, and fileproviderd refuses to sync it. There is no API to enable it. | `fileproviderctl dump io.github.krisarmstrong.ferry.provider`: `(⏹ user-disabled)`, `enabled: no`, `NSError: FP -2011 "Sync is not enabled" domain:domainDisabled`. Enumerator not called. The Finder sidebar was not checked visually. |
| Step 4: "would like to access data from other apps" prompt for the team-prefixed group with development signing | **No prompt** for the agent or the app. containermanagerd approves on the signature. Not tested for the sandboxed extension, which never ran. | `containermanagerd: [io.github.krisarmstrong.ferry.agent] requesting ...: APPROVED. Requestor's signature allows it to access a TCC-protected group container` (same line for `io.github.krisarmstrong.ferry`); the write completed in 4 ms. |
| Cleanup | Done. | `agent remove(agent): ok`, `app remove: ok`, `domains: []`; `unregister: ok`, `status=0`; `launchctl print` → `Could not find service`; `lsregister -u`, then `pluginkit -m -i ...provider` → `(no matches)`; spike files removed from the group container; `spikes/` deleted. |

## Consequences for Plan 2

- Domains can stay in the agent (Tasks 4 and 6 unchanged).
- The product must handle `userEnabled == false`. After `add`, the menu bar must tell the user to
  turn on Ferry in System Settings → General → Login Items & Extensions → File Providers (or the
  Finder prompt). Treat a disabled domain as a normal state, not an error.
- Extension → agent XPC from inside the sandbox is still unproven. Recheck it in Task 6's smoke
  test once the owner has enabled Ferry: expect `extension got: pong ...`, or a `Sandbox` denial
  for `mach-lookup`.

Decision: domains managed by agent; group X6JWYP43HG.io.github.krisarmstrong.ferry; profile automatic (no profile needed for development signing with the team-prefixed group; portal and Developer ID path unexercised)
