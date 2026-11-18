# Ferry Finder Integration Implementation Plan (Plan 2 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plug in a NetAlly LinkRunner 10G / EtherScope nXG / LinkRunner 100G (or an Android
phone) and its storage appears in Finder's sidebar, with browse, open, copy both ways, new
folder, rename, move and delete. A menu-bar item shows devices and transfers, and a setup guide
explains how to turn on file transfer.

**Architecture:** Three processes in one app bundle. `FerryAgent` is an unsandboxed launch agent
registered with `SMAppService`. It is the only process that touches USB. It owns every
`DeviceSession` through a `DeviceHub`, manages one `NSFileProviderDomain` per storage, and
vends an XPC Mach service. `FerryProvider.appex` is a sandboxed
`NSFileProviderReplicatedExtension` that forwards each call over XPC. `Ferry.app` is a SwiftUI
`MenuBarExtra` that registers the agent and shows status. All logic that can be tested without
the system lives in SwiftPM libraries: `FerryIPC`, `FerryAgentCore` and `FerryProviderCore`.
The Xcode targets are thin shells built from an XcodeGen `project.yml`.

**Tech Stack:** Swift 6.4 (language mode 6), SwiftUI, FileProvider (replicated), XPC
(`NSXPCConnection`), ServiceManagement (`SMAppService`), IOKit USB notifications, XcodeGen
2.46.0, Swift Testing, Plan 1's DeviceKit / MTPTransport.

**Spec:** `docs/superpowers/specs/2026-11-17-ferry-design.md`. Plan 1's "Plan 2 entry rows" are
in `docs/superpowers/plans/2026-11-17-ferry-core-transport.md`.

## Global Constraints

- macOS 26 minimum, arm64 only. Swift 6 language mode with strict concurrency, zero warnings
  except the two accepted Homebrew libmtp warnings (removed in Plan 3).
- Async/await and actors only. No locks, and no GCD except a `DispatchSerialQueue` used as an
  actor executor. XPC reply blocks are bridged with checked continuations.
- SwiftUI for all UI. `@Observable`, not `ObservableObject`. `MenuBarExtra` and `Settings`
  scenes, SF Symbols, system materials, no custom chrome. All user-facing strings in a String
  Catalog.
- Swift Testing for unit tests. `os.Logger` with subsystem `io.github.krisarmstrong.ferry`.
  File names are logged `privacy: .private` (entry row).
- Identifiers:
  - Team: `X6JWYP43HG`.
  - App: `io.github.krisarmstrong.ferry`.
  - Agent: `io.github.krisarmstrong.ferry.agent`.
  - Extension: `io.github.krisarmstrong.ferry.provider`.
  - App group: `X6JWYP43HG.io.github.krisarmstrong.ferry`. Task 0 may change this and must
    record the change.
  - XPC Mach service: `X6JWYP43HG.io.github.krisarmstrong.ferry.agent`. It must start with the
    app group so the sandboxed extension may look it up.
- Domain identifier: `<serial>|<StorageID.key>`. Domain display name: `<Model>` or
  `<Model> (<last 4 of serial>)` when two attached devices share a model, plus ` – SD card` for
  a secondary storage (spec).
- Item identifier: an opaque, stable, agent-assigned ID (spec "Item identity", amended after
  Task 5). `NSFileProviderItemIdentifier.rootContainer` is the storage root. Neither paths nor
  MTP object IDs leave the agent as identifiers.
- An unplugged device's domain is disconnected, not removed. "Eject" removes it. "Remove Ferry"
  removes all domains and then unregisters the agent (spec).
- No telemetry, no network, no AI, no NetAlly logos or branding. Model names are used only to
  identify devices.
- Work on branch `feat/finder-integration`, cut from `feat/core-transport`.

## Review Focus

1. **Device unplugged while Finder is browsing or copying.** Every pending extension call must
   finish promptly with `NSFileProviderError(.serverUnreachable)`, the domain shows as
   disconnected, and nothing hangs Finder. Tests: Task 1 `disconnectReleasesHandleAndFailsFast`,
   Task 4 `unplugDisconnectsDomainAndFailsPending`, Task 5 `disconnectedMapsToServerUnreachable`.
2. **Finder copies a folder of many files.** FileProvider calls `createItem` concurrently. The
   per-session gate must serialize them without deadlock, and every file must land. Tests:
   Task 1 `concurrentOperationsAreSerialized`, Task 5 `concurrentCreatesAllLand`.
3. **Replug the same device.** The same domain reconnects with no duplicate domain and no
   duplicate items. Test: Task 4 `replugReconnectsSameDomain`.
4. **Device connected but not sharing files** (the LinkRunner before "Transfer files"). There
   is no domain. The menu shows the device as "Not sharing files" and opens the setup guide for
   its model. Tests: Task 4 `lockedDeviceGetsNoDomainAndReportsState`, Task 7
   `guideStepsForNetAllyModels`.
5. **Case-only rename in Finder** (`a.txt` → `A.txt`). It renames rather than failing as
   "already exists". Test: Task 5 `caseOnlyRenameSucceeds` (MTPSession already passes
   `except:`; this pins it end to end).

---

### Task 0: Signing and IPC spike (throwaway, decides the setup)

Proves the three risky platform assumptions before product code. Throwaway code lives in
`spikes/fileprovider/` and is deleted at the end of the task. Only the findings doc stays.
**May need the owner** to sign in to Xcode (Settings → Accounts) with the Apple ID of team
`X6JWYP43HG`, because the Xcode account list is currently empty.

**Files:**
- Create: `docs/spikes/2026-11-fileprovider-xpc.md`

- [ ] **Step 1:** Build a minimal app, appex and agent from a throwaway `project.yml` with the
  identifiers in Global Constraints, signed with "Apple Development" for team `X6JWYP43HG`. Use
  `xcodebuild -allowProvisioningUpdates`. Record whether a provisioning profile with App Groups
  and the FileProvider extension point was created automatically. If not, record exactly what
  the owner must do in the developer portal.
- [ ] **Step 2:** Run the app. It registers `SMAppService.agent(plistName:)`, and the agent
  vends `NSXPCListener(machServiceName:)`. From the extension, connect and round-trip a ping.
  Record success, or the exact sandbox denial (from `log stream --predicate 'sender ==
  "Sandbox"'`).
- [ ] **Step 3:** From the **agent**, call `NSFileProviderManager.add(_:)` for a test domain.
  Check that it appears in Finder's sidebar and that the extension's enumerator is called.
  If the agent is refused, retry from the app and record which process must own domain
  management.
- [ ] **Step 4:** Record whether macOS 26/27 prompts "would like to access data from other
  apps" for the team-prefixed app group, signed with a development profile.
- [ ] **Step 5:** Write the spike doc with a table of assumption → result and the final
  identifiers. End it with `Decision: domains managed by <agent|app>; group <id>; profile
  <automatic|manual: steps>`. Delete `spikes/`. Commit `docs: record FileProvider/XPC spike`.

If Step 3 shows the app must manage domains, Tasks 4 and 6 move domain calls to the app,
driven by agent events over XPC. Rule on it in the ledger and update those tasks' briefs.

---

### Task 1: Session safety rows from Plan 1 (DeviceKit / MTPTransport)

**Files:**
- Modify: `Sources/MTPTransport/MTPSession.swift`, `Sources/MTPTransport/MTPDevice.swift`,
  `Sources/DeviceKit/DeviceTransport.swift`, `Sources/DeviceKit/SafeWriter.swift`,
  `Sources/DeviceKitTestSupport/FakeTransport.swift`, `Sources/ferryctl/Commands.swift`
- Test: `Tests/MTPTransportTests/MTPSessionGateTests.swift`,
  `Tests/MTPTransportTests/MTPSessionDownloadTests.swift`, `Tests/DeviceKitTests/SafeWriterTests.swift`

**Interfaces — Produces:**
```swift
// DeviceTransport.swift (contract change; every conformer and caller updated)
func download(_ path: RemotePath, in storage: StorageID, to file: URL, replacing: Bool,
              progress: ProgressHandler) async throws(TransportError)
// SafeWriter
public func registerInFlight(_ path: RemotePath, in storage: StorageID) async   // used by MTPSession move fallback via an injected registry
// MTPSession: internal OperationGate actor — `func run<T>(_ body: () async throws(TransportError) -> T) async throws(TransportError) -> T`, FIFO, non-reentrant
```
Rules, all from the Plan 1 entry rows:
- Every public `MTPSession` operation runs inside the gate.
- The parent is invalidated before each existence check.
- `list()` throws when libmtp reports errors alongside a partial list.
- The `copyThenDelete` partial is registered with the session's SafeWriter registry. The
  registry is passed into `MTPSession` at init, and `SafeWriter(session:)` reuses it.
- On `.deviceDisconnected`, `MTPDevice` closes its handle, and every later call throws
  `.deviceDisconnected` immediately, without USB I/O.
- `download(replacing: false)` moves the partial into place with
  `renamex_np(partial, file, RENAME_EXCL)`. `EEXIST` maps to `.alreadyExists`. `ENOTSUP` falls
  back to the existence check plus `rename(2)`, with a logged warning.
- Every file name logged anywhere becomes `privacy: .private`.

- [ ] **Step 1: Write failing tests:**
  - `concurrentOperationsAreSerialized`: 20 concurrent uploads. The stub records no overlapping
    device calls, and all 20 land.
  - `gateIsFIFO`.
  - `existenceCheckSeesPhoneSideAddition`: after the folder is cached, the stub adds `x` behind
    the session's back. Uploading `x` then throws `.alreadyExists`.
  - `partialListingThrows`.
  - `moveFallbackPartialSurvivesConcurrentListing`.
  - `disconnectReleasesHandleAndFailsFast`: after a disconnect, the next call throws
    `.deviceDisconnected` and the stub sees zero calls.
  - `downloadWithoutReplaceRefusesFileCreatedMidDownload`.
  - `downloadReplacingOverwrites`.
- [ ] **Step 2:** `swift test --filter 'MTPSessionGateTests|MTPSessionDownloadTests'`. Expect
  FAIL.
- [ ] **Step 3:** Implement the rules above. Update `ferryctl get` to pass `replacing:`.
- [ ] **Step 4:** Run `make test lint fmt-check` and expect it to pass. Then run
  `FERRY_DEVICE_TESTS=1 swift test --filter DeviceTests` on the LinkRunner with file transfer on,
  and expect it to pass.
- [ ] **Step 5:** Commit `feat: serialize session operations and harden download and disconnect`.

---

### Task 2: DeviceHub — held-device registry and USB arrival/departure

**Files:**
- Create: `Sources/DeviceKit/AttachedDevice.swift` (`DeviceState`, `AttachedDevice`, `Codable`, shared by IPC and UI)
- Create: `Sources/FerryAgentCore/DeviceHub.swift`, `Sources/FerryAgentCore/USBWatcher.swift`
- Modify: `Package.swift` (add the library `FerryAgentCore`, which depends on DeviceKit and
  MTPTransport, and the test target `FerryAgentCoreTests`)
- Test: `Tests/FerryAgentCoreTests/DeviceHubTests.swift`

**Interfaces — Produces:**
```swift
// DeviceKit
public enum DeviceState: Sendable, Equatable, Codable { case ready([StorageInfo]), notSharingFiles, busy, failed(TransportError) }
public struct AttachedDevice: Sendable, Equatable, Codable, Identifiable { public let info: DeviceInfo; public let state: DeviceState; public var id: DeviceID { info.id } }
// FerryAgentCore
public enum HubEvent: Sendable, Equatable { case attached(AttachedDevice), changed(AttachedDevice), detached(DeviceID) }
public actor DeviceHub {
  public init(transport: any DeviceTransport, arrivals: AsyncStream<Void>)   // arrivals: any USB attach/detach tick
  public var events: AsyncStream<HubEvent> { get }
  public func devices() -> [AttachedDevice]
  public func session(for id: DeviceID) throws(TransportError) -> any DeviceSession   // the one held session; never re-opens a held device
  public func recheck(_ id: DeviceID) async      // re-reads storages (e.g. after "Transfer files" is enabled)
  public func eject(_ id: DeviceID) async        // closes the session; device stays listed as .notSharingFiles until replugged
}
public struct USBWatcher: Sendable {           // IOKit IOServiceAddMatchingNotification on kIOUSBHostDeviceClassName, first-match + terminate
  public static func ticks() -> AsyncStream<Void>
}
```
Rules:
- The hub owns every session. A device already held is never reported as `.busy`
  (entry row).
- `.deviceLocked` from `storages()` becomes `.notSharingFiles`, and the hub re-checks it every
  2 s while any device is in that state. This bounded re-check is the one allowed poll: MTP has
  no "file transfer enabled" event. It stops when no device is waiting.
- A detach closes the session and emits `.detached`.

- [ ] **Step 1: Write failing tests** against `FakeTransport` with a manual `arrivals`
  continuation:
  - `attachEmitsReadyWithStorages`.
  - `lockedDeviceIsNotSharingFilesThenBecomesReady`, where the fake unlocks after one recheck.
  - `heldDeviceIsNeverBusy`.
  - `detachClosesSessionAndEmits`.
  - `ejectKeepsDeviceListed`.
  - `noPollingWhenNothingWaits`, using an injected clock.
- [ ] **Step 2:** `swift test --filter DeviceHubTests`. Expect FAIL.
- [ ] **Step 3:** Implement. `USBWatcher` has no unit test. It is covered by the Task 8 manual
  check.
- [ ] **Step 4:** Run `make test lint fmt-check` and expect it to pass.
- [ ] **Step 5:** Commit `feat: add DeviceHub and USB watcher`.

---

### Task 3: FerryIPC — agent protocol over XPC

**Files:**
- Create: `Sources/FerryIPC/Messages.swift`, `Sources/FerryIPC/AgentXPC.swift`,
  `Sources/FerryIPC/AgentClient.swift`
- Modify: `Package.swift` (add the library `FerryIPC`, which depends on DeviceKit, and the test
  target `FerryIPCTests`)
- Test: `Tests/FerryIPCTests/MessagesTests.swift`, `Tests/FerryIPCTests/AgentClientTests.swift`

**Interfaces — Produces:**
```swift
public enum AgentRequest: Codable, Sendable {
  case status, recheck(DeviceID), eject(DeviceID), removeAllDomains     // .status ⇒ .status(devices:providerEnabled:)
  case item(domain: String, path: RemotePath), list(domain: String, folder: RemotePath)
  case fetch(domain: String, path: RemotePath)                                 // + writable FileHandle
  case create(domain: String, path: RemotePath, isFolder: Bool)                 // + readable FileHandle for files
  case rename(domain: String, path: RemotePath, to: String)
  case move(domain: String, path: RemotePath, toFolder: RemotePath)
  case replaceContents(domain: String, path: RemotePath)                        // + readable FileHandle
  // (Task 4 security fix: file contents travel as file descriptors, never paths)
  case delete(domain: String, path: RemotePath)
}
public enum AgentResponse: Codable, Sendable { case status(devices: [AttachedDevice], providerEnabled: Bool), item(RemoteItem), items([RemoteItem]), done, failure(TransportError) }
@objc public protocol AgentXPC { func send(_ request: Data, file: FileHandle?, reply: @escaping @Sendable (Data) -> Void) }   // JSON both ways
public protocol AgentSending: Sendable { func send(_ request: AgentRequest) async throws(TransportError) -> AgentResponse }
public actor AgentClient: AgentSending {
  public init(machServiceName: String)
  public func send(_ request: AgentRequest) async throws(TransportError) -> AgentResponse   // connection loss ⇒ .deviceDisconnected
}
public protocol AgentHandling: Sendable { func handle(_ request: AgentRequest) async -> AgentResponse }
public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable { public init(handler: any AgentHandling) }
```
`TransportError` must become `Codable` (Task 2 already made `AttachedDevice` and `DeviceState`
Codable in DeviceKit). FerryIPC depends only on DeviceKit.

- [ ] **Step 1: Write failing tests:**
  - `everyRequestRoundTripsJSON`.
  - `everyErrorRoundTripsJSON`.
  - `clientServerOverAnonymousListener`: use `NSXPCListener.anonymous()` with a stub
    `AgentHandling`, send `.list`, get `.items`.
  - `connectionLossMapsToDisconnected`: invalidate the listener mid-call.
- [ ] **Step 2:** `swift test --filter FerryIPCTests`. Expect FAIL.
- [ ] **Step 3:** Implement. Bridge XPC replies to async with checked continuations. Use
  `remoteObjectProxyWithErrorHandler` so an interrupted connection resumes the continuation
  exactly once.
- [ ] **Step 4:** Run `make test lint fmt-check` and expect it to pass.
- [ ] **Step 5:** Commit `feat: add FerryIPC agent protocol`.

---

### Task 4: Agent core — domains and request handling

**Files:**
- Create: `Sources/FerryAgentCore/DomainController.swift`,
  `Sources/FerryAgentCore/AgentService.swift`, `Sources/FerryAgentCore/DomainNaming.swift`
- Test: `Tests/FerryAgentCoreTests/DomainControllerTests.swift`,
  `Tests/FerryAgentCoreTests/AgentServiceTests.swift`

**Interfaces — Produces:**
```swift
public struct DomainSpec: Sendable, Hashable { public let identifier: String; public let displayName: String }  // identifier "<serial>|<StorageID.key>"
public protocol DomainManaging: Sendable {        // real impl wraps NSFileProviderManager; tests use a fake
  func add(_ spec: DomainSpec) async throws
  func disconnect(_ identifier: String) async throws
  func reconnect(_ identifier: String) async throws
  func remove(_ identifier: String) async throws
  func removeAll() async throws
  func signal(_ identifier: String, folder: RemotePath) async
  func isUserEnabled() async -> Bool              // any Ferry domain's NSFileProviderDomain.userEnabled (Task 0: new domains start disabled)
}
public enum DomainNaming { public static func specs(for devices: [AttachedDevice]) -> [DomainSpec] }   // spec's naming rule
public actor DomainController { public init(hub: DeviceHub, manager: any DomainManaging); public func run() async }  // consumes hub.events
public actor AgentService: AgentHandling { public init(hub: DeviceHub, domains: DomainController) }   // routes requests to the held session via SafeWriter for writes
```
Rules:
- `.ready` adds a domain for each new spec and reconnects existing ones.
- `.detached` disconnects (it never removes).
- `.notSharingFiles` adds no domain.
- `eject` removes that device's domains. `removeAllDomains` removes everything.
- Every write goes through one `SafeWriter` per session.
- After any mutation, the agent signals the parent folder.
- `fetch` downloads with `replacing: true` into the given URL.

- [ ] **Step 1: Write failing tests:**
  - `namesDisambiguateSameModelAndSDCard`.
  - `readyDeviceAddsOneDomainPerStorage`.
  - `lockedDeviceGetsNoDomainAndReportsState`.
  - `unplugDisconnectsDomainAndFailsPending`: a pending `.list` returns
    `.failure(.deviceDisconnected)`.
  - `replugReconnectsSameDomain`: no second `add`.
  - `ejectRemovesOnlyThatDevice`.
  - `writeGoesThroughSafeWriterAndSignals`.
  - `unknownDomainFails`.
- [ ] **Step 2:** `swift test --filter FerryAgentCoreTests`. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test lint fmt-check` and expect it to pass.
- [ ] **Step 5:** Commit `feat: add agent domain controller and request service`.

---

### Task 5: Provider core — FileProvider mapping

**Files:**
- Create: `Sources/FerryProviderCore/ProviderItem.swift`,
  `Sources/FerryProviderCore/ProviderBackend.swift`, `Sources/FerryProviderCore/ErrorMapping.swift`
- Modify: `Package.swift` (add the library `FerryProviderCore`, which depends on FerryIPC, and
  the test target `FerryProviderCoreTests`)
- Test: `Tests/FerryProviderCoreTests/ProviderBackendTests.swift`

**Interfaces — Produces:**
```swift
public final class ProviderItem: NSObject, NSFileProviderItem, Sendable   // from RemoteItem; identifier = path string; root ↔ .rootContainer;
                                                                          // itemVersion = (size, modified) encoded; capabilities: read/write/rename/reparent/delete (+addSubItems for folders)
public actor ProviderBackend {                                            // everything the appex does, minus the NSFileProviderReplicatedExtension shell
  public init(domain: String, client: any AgentSending)                  // AgentSending: protocol over AgentClient.send for fakes
  public func item(_ id: NSFileProviderItemIdentifier) async throws -> ProviderItem
  public func children(of id: NSFileProviderItemIdentifier) async throws -> [ProviderItem]
  public func fetch(_ id: NSFileProviderItemIdentifier, into dir: URL) async throws -> (URL, ProviderItem)
  public func create(_ template: NSFileProviderItem, contents: URL?) async throws -> ProviderItem
  public func modify(_ item: NSFileProviderItem, changed: NSFileProviderItemFields, contents: URL?) async throws -> ProviderItem
  public func delete(_ id: NSFileProviderItemIdentifier) async throws
}
public enum ErrorMapping { public static func fileProviderError(_ e: TransportError) -> Error }
```
Error mapping:
- `.notFound` → `NSFileProviderError(.noSuchItem)`
- `.alreadyExists` → `.filenameCollision`
- (Task 4) `fetch`/`create`/`replaceContents` open their own file (in the extension's container)
  and send a `FileHandle`; a `fetch` that does not return `.done` is a failure, and the target
  file is discarded, never handed to FileProvider (it may hold a truncated prefix).
- `.deviceDisconnected`, `.deviceBusy` and `.noDeviceConnected` → `.serverUnreachable`
- `.deviceLocked` → `.notAuthenticated`
- `.insufficientSpace` and `.fileTooLargeForStorage` → `.insufficientQuota`
- everything else → `NSError` with a localized description

`modify` handles the changed fields in this order: parent (move), then filename (rename), then
contents (`replaceContents`).

- [ ] **Step 1: Write failing tests** with a fake `AgentSending`:
  - `rootMapsToRootContainer`.
  - `childrenBuildItemsWithPaths`.
  - `fetchReturnsFileInDir`.
  - `createFileAndFolder`.
  - `concurrentCreatesAllLand`: 20 concurrent creates, all sent.
  - `modifyRenameMoveAndContentsInOrder`.
  - `caseOnlyRenameSucceeds`: the fake agent applies MTPSession's `except:` rule.
  - `disconnectedMapsToServerUnreachable`.
  - `everyTransportErrorMaps`: exhaustive.
  - `versionChangesWhenSizeOrDateChanges`.
- [ ] **Step 2:** `swift test --filter FerryProviderCoreTests`. Expect FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `make test lint fmt-check` and expect it to pass.
- [ ] **Step 5:** Commit `feat: add FileProvider mapping core`.

---

### Task 5b: Stable item identifiers (amendment)

Added after Task 5: path-as-identifier breaks FileProvider (a changed identifier on modify means
"merge and delete the other") and leaks file names into system logs. One unit across FerryIPC,
FerryAgentCore and FerryProviderCore, reviewed together with Task 5.

**Files:**
- Create: `Sources/FerryAgentCore/ItemTable.swift` (per-domain identifier ↔ path table, persisted
  as one JSON file per domain under the agent's Application Support, atomic writes)
- Modify: `Sources/FerryIPC/Messages.swift`, `Sources/FerryAgentCore/AgentService.swift`,
  `Sources/FerryAgentCore/DomainController.swift`, `Sources/FerryProviderCore/*`
- Test: `Tests/FerryAgentCoreTests/ItemTableTests.swift`, plus updates to the IPC, agent and
  provider tests

**Interfaces — Produces:**
```swift
public struct ItemID: Hashable, Sendable, Codable, RawRepresentable { public static let root: ItemID }  // root ↔ .rootContainer
public struct ProviderEntry: Sendable, Codable, Equatable { public let id: ItemID; public let parent: ItemID; public let item: RemoteItem }
// AgentRequest cases take ItemIDs: item(domain:id:), list(domain:folder:), fetch(domain:id:),
// create(domain:parent:name:isFolder:), rename(domain:id:to:), move(domain:id:toFolder:),
// replaceContents(domain:id:), delete(domain:id:). Responses: .entry(ProviderEntry), .entries([ProviderEntry]).
actor ItemTable {
  init(domain: String, store: URL)                  // loads; missing file ⇒ empty
  func id(for path: RemotePath) -> ItemID           // assigns on first sight
  func path(for id: ItemID) -> RemotePath?          // nil ⇒ .notFound
  func moved(_ from: RemotePath, to: RemotePath)    // rewrites the subtree, IDs unchanged
  func removed(_ path: RemotePath)                  // prunes the subtree
  func listed(_ folder: RemotePath, children: [String])  // prunes children that vanished
}
public struct ItemTemplate: Sendable { public let parent: ItemID; public let filename: String; public let isFolder: Bool }
// ProviderBackend.create/modify take ItemTemplate (and changed fields) instead of `any NSFileProviderItem` (Task 5 Sendable finding)
```
Rules:
- IDs are random (UUID strings), never derived from names.
- The table persists across agent restarts, so Finder's cached items keep their identity.
- Signals target the working set only (replicated extensions ignore other containers); the
  agent's change log feeds the working-set enumerator via `.changes(domain:since:)` (fix round 1).

- [ ] **Step 1: Write failing tests:**
  - `idsAreStableAcrossRenameAndMove`
  - `subtreeMovesKeepIDs`
  - `deletePrunes`
  - `listingPrunesVanishedChildren`
  - `tablePersistsAcrossReload`
  - `idsContainNoNames`
  - `unknownIDIsNotFound`
  - `modifyReturnsSameIdentifier` (provider)
  - `templateIsSendableSnapshot` (provider)
- [ ] **Step 2:** Run the new tests and confirm they FAIL.
- [ ] **Step 3:** Implement. Migrate all IPC, agent and provider code and their tests.
- [ ] **Step 4:** Run `make test lint fmt-check` and confirm it passes.
- [ ] **Step 5:** Commit `feat: give items stable identifiers`.

---

### Task 6: App bundle — XcodeGen project, agent, extension shells

**Files:**
- Create: `project.yml`
- Create: `Apps/FerryAgent/main.swift` (wires `MTPTransport`, `DeviceHub`, `DomainController`,
  `AgentService` and the `NSXPCListener(machServiceName:)`)
- Create: `Apps/FerryAgent/io.github.krisarmstrong.ferry.agent.plist` (`BundleProgram`,
  `MachServices`)
- Create: `Apps/FerryProvider/FileProviderExtension.swift` (an
  `NSFileProviderReplicatedExtension` shell over `ProviderBackend`) and
  `Apps/FerryProvider/Enumerator.swift`
- Create: `Apps/FerryProvider/Info.plist` and `FerryProvider.entitlements` (sandbox and app
  group)
- Create: `Apps/Ferry/FerryApp.swift` (placeholder `MenuBarExtra`; filled in Task 7),
  `Ferry.entitlements` and `Info.plist` (`LSUIElement`)
- Modify: `Makefile` (`app` = `xcodegen && xcodebuild -scheme Ferry -allowProvisioningUpdates
  build`; `.gitignore` already ignores `*.xcodeproj`)

Notes:
- The bundle layout is the spec's: the agent at `Contents/MacOS/FerryAgent`, its plist in
  `Contents/Library/LaunchAgents/`, and the appex in `Contents/PlugIns/`.
- Homebrew libmtp and libusb are linked from `/opt/homebrew` for development. Plan 3 bundles
  them.
- `NSFileProviderManager` calls go into a `DomainManaging` implementation in the agent, or in
  the app if Task 0 decided so.

- [ ] **Step 1:** Write `project.yml` and the shells. The shells contain no logic beyond wiring.
- [ ] **Step 2:** Run `make app`. Expect a build with zero warnings beyond the accepted two.
  `codesign -d --entitlements -` on the app, agent and appex must show the Task 0 identifiers.
- [ ] **Step 3:** Smoke test. Launch the app; it registers the agent (an `SMAppService.status`
  of `.enabled` is logged). The owner enables Ferry under System Settings → General → Login
  Items & Extensions → File Providers (Task 0: domains start disabled). Confirm the sandboxed
  extension reaches the agent's Mach service (Task 0 could not; look for a `Sandbox`
  `mach-lookup` denial if not). With the LinkRunner in file-transfer mode, "LinkRunner-100G"
  appears in Finder's sidebar and `ls`-equivalent browsing in Finder matches `ferryctl ls /`.
- [ ] **Step 4:** Commit `feat: add app bundle with agent and FileProvider extension`.

---

### Task 7: Menu bar and setup guide

**Files:**
- Create: `Sources/FerryUI/MenuContent.swift`, `Sources/FerryUI/SetupGuide.swift`,
  `Sources/FerryUI/GuideSteps.swift`, `Sources/FerryUI/AppModel.swift` (`@Observable`),
  `Sources/FerryUI/Localizable.xcstrings`
- Modify: `Package.swift` (add the library `FerryUI`, which depends on FerryIPC, and the test
  target `FerryUITests`), `Apps/Ferry/FerryApp.swift`
- Test: `Tests/FerryUITests/GuideStepsTests.swift`, `Tests/FerryUITests/AppModelTests.swift`

**Interfaces — Produces:**
```swift
public enum DeviceFamily: Sendable, CaseIterable { case netAllyAndroid8Board, otherAndroid8to9, otherAndroid10Plus }   // AirCheck G3 later
public enum GuideSteps {
  public static func family(forModel model: String) -> DeviceFamily?   // "LinkRunner 10G", "LinkRunner-100G", "EtherScope nXG" (case/hyphen-insensitive) ⇒ .netAllyAndroid8Board; unknown ⇒ nil
  public static func steps(for family: DeviceFamily) -> [LocalizedStringResource]
}
@Observable @MainActor public final class AppModel {
  public init(client: any AgentSending)
  public private(set) var devices: [AttachedDevice]
  public var guideFamily: DeviceFamily?          // set ⇒ sheet shown
  public private(set) var providerEnabled: Bool   // false ⇒ "Turn on Ferry in Finder" row with a button opening
                                                  // x-apple.systempreferences:com.apple.LoginItems-Settings.extension
  public func refresh() async; public func eject(_ id: DeviceID) async; public func removeFerry() async
}
```
Copy, verbatim from the spec's setup-guide section:
- **NetAlly steps:** connect the left USB-C port → Settings → Connected devices → USB → Transfer
  files.
- **Generic Android 8–9:** USB charging this device → Transfer files.
- **Generic Android 10+:** Charging this device via USB → USB preferences → File transfer; also
  "unlock the phone first".

Menu contents:
- Each device, showing its model and its state. "Ready" lists its storages; "Not sharing
  files" has a "How to turn on file transfer" button. Each device also has Eject.
- "No device connected", with "How to connect".
- Refresh.
- Settings…, which includes "Open at login" (`SMAppService` register/unregister) and "Remove
  Ferry…" with a confirmation.
- Quit.

The guide sheet opens automatically the first time a device becomes `.notSharingFiles`, and
when nothing has been detected for 10 s after the menu opens. Without a known model it shows a
model picker.

- [ ] **Step 1: Write failing tests:**
  - `disabledProviderShowsTurnOnRow`: `providerEnabled == false` ⇒ the model exposes the turn-on
    action, and it is not treated as an error.
  - `guideStepsForNetAllyModels`: all three model spellings, including the LinkRunner's
    reported `LinkRunner-100G`, map to `.netAllyAndroid8Board`, with 3 steps that mention
    "Transfer files".
  - `unknownModelHasNoFamily`.
  - `notSharingFilesOpensGuideOnce`.
  - `removeFerryCallsRemoveAllThenUnregister`: the order is checked with fakes.
- [ ] **Step 2:** `swift test --filter FerryUITests`. Expect FAIL.
- [ ] **Step 3:** Implement the views using standard controls and SF Symbols only
  (`externaldrive.connected.to.line.below`, `cable.connector`, `questionmark.circle`). Previews
  for each state.
- [ ] **Step 4:** Run `make test lint fmt-check app` and expect it to pass.
- [ ] **Step 5:** Commit `feat: add menu bar and file-transfer setup guide`.

---

### Task 8: End-to-end on the LinkRunner (needs owner)

**Files:**
- Modify: `docs/TESTING.md` (add a "Finder" checklist and a results row)

- [ ] **Step 1: Run the checklist** with the LinkRunner and record each result:
  - First run: the menu shows "Turn on Ferry in Finder". The button opens Login Items &
    Extensions; after enabling Ferry under File Providers, the row disappears.
  - Plug in with file transfer off. The menu shows "Not sharing files" and the guide opens with
    the NetAlly steps.
  - Enable Transfer files. The domain appears within 5 s.
  - In Finder:
    - Browse `/Download`.
    - Open a file in Preview.
    - Copy a 1 GB file to the device, then copy it back and check it with `shasum -a 256`.
    - Copy a folder of 50 files to the device.
    - New Folder, rename, case-only rename, move between folders, then delete to Trash and
      empty.
  - Unplug mid-copy. Finder shows an error, does not hang, and the location shows as
    unavailable. Replug: the same location returns.
  - Eject. Then Remove Ferry: the location is gone and the agent is unregistered
    (`launchctl print gui/$UID/io.github.krisarmstrong.ferry.agent` fails).
- [ ] **Step 2:** Record the results in `docs/TESTING.md` and commit
  `docs: record Finder end-to-end results`.
