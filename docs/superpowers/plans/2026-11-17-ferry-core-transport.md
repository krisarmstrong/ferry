# Ferry Core Transport Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the phone-grab spike, then build the device layer with a
`ferryctl` CLI. After this plan, `ferryctl` can list, download, upload,
rename, move and delete files on a USB-attached Android phone, with the
design's write-safety rules.

**Architecture:** A SwiftPM package. `DeviceKit` holds transport-neutral types,
the `DeviceTransport`/`DeviceSession` protocols and `SafeWriter`, which carries
the write-safety logic. `MTPTransport` implements those protocols over libmtp,
using a path→object-ID resolver and an actor on a dedicated serial executor,
because libmtp calls block. `ferryctl` is a thin CLI over them. The agent, XPC,
FileProvider extension and menu app are **Plan 2**. Signing, notarization,
bundled dylibs built from source, and the cask are **Plan 3**.

**Tech Stack:** Swift 6.4 (language mode 6, strict concurrency), SwiftPM
(tools 6.4), Swift Testing, libmtp 1.1.23 + libusb 1.0.30 (Homebrew,
pkg-config), swift-argument-parser 1.8.2, SwiftLint 0.65.1, swift-format
(Xcode toolchain).

**Spec:** `docs/superpowers/specs/2026-11-17-ferry-design.md`

## Global Constraints

- macOS 26 minimum (`platforms: [.macOS(.v26)]`), arm64 only.
- Swift 6 language mode, strict concurrency, zero warnings. Use async/await and
  actors only, with no GCD callbacks and no locks. The one exception is a
  `DispatchSerialQueue` used as an actor's executor.
- Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The
  Makefile exports it.
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`), not
  XCTest.
- Log with `os.Logger`, subsystem `io.github.krisarmstrong.ferry`. No `print`
  outside `ferryctl` output.
- The code is MIT-licensed. libmtp and libusb are LGPL-2.1 and linked
  dynamically only.
- Sizes are `UInt64` everywhere, so files over 4 GB never pass through 32 bits.
- Temp-name prefix is `.ferry-partial-`; the full name is
  `.ferry-partial-<UUID>`.
- No telemetry, no network calls, no AI.
- Pin dependencies to exact versions (`exact:`).
- Support Android 8+. Decide behaviour by device capability, never by Android
  version.

## Review Focus

1. **Locked phone:** the phone reports zero storages until it is unlocked.
   Expect `TransportError.deviceLocked`, not an empty device or a crash.
   Test: Task 2, `fakeLockedDeviceThrowsDeviceLocked`; Task 4,
   `storagesEmptyMapsToLocked`.
2. **Unicode names from Finder:** macOS hands over decomposed (NFD) names and
   Android stores composed (NFC). Uploading `café` from Finder must not create
   a second, look-alike `café`. Names are NFC-normalized on the way out and
   compared normalized. Test: Task 1, `remotePathNormalizesToNFC`; Task 3,
   `uploadOverNFDNameReplacesExisting`.
3. **Unplug mid-upload:** no partial file may show up under the real name, and
   the next listing of that folder must hide and delete the leftover partial.
   Test: Task 3, `disconnectMidUploadLeavesNoFinalName` and
   `listingHidesAndDeletesPartials`.
4. **File over 4 GB to a FAT32 SD card:** the device rejects the send, or keeps
   fewer bytes than were sent. Expect `fileTooLargeForStorage` or
   `sizeMismatch`, with the partial deleted. Never a truncated file. Test:
   Task 3, `oversizeRejectionMapsToTooLarge` and
   `shortWriteThrowsSizeMismatchAndCleansUp`.
5. **Duplicate names in one MTP folder:** possible on some devices. Resolve
   deterministically to the lowest object ID and never crash. Test: Task 4,
   `duplicateNamesResolveToLowestID`.

---

### Task 0: Phone-grab spike (no product code)

The design requires this to happen first. The outcome picks step 1, 2 or 3 of
the owner's escalation order: claim with nothing extra, pause `ptpcamerad` as
the user, or a privileged helper. **Needs the owner and at least one phone, an
Android 8/9 phone if available.**

**Files:**
- Create: `docs/spikes/2026-11-ptpcamerad.md`

- [ ] **Step 1:** Commit the existing docs on `main` with
  `git add docs && git commit -m "docs: add ferry design and core plan"`.
  Then create the branch: `git switch -c feat/core-transport`.
- [ ] **Step 2:** Plug in the phone, unlocked, in "File transfer" mode. Run
  `pgrep -lf ptpcamerad; mtp-detect 2>&1 | tail -20`.
  Record whether `ptpcamerad` is running and whether `mtp-detect` opened the
  device. A failure looks like `LIBMTP_ERROR_CONNECTING` or "Unable to open
  raw device".
- [ ] **Step 3:** If step 2 failed, run `killall ptpcamerad; mtp-detect`
  as the user, without sudo. Record whether that succeeds, and whether
  `ptpcamerad` restarts within 10 s (`sleep 10; pgrep -lf ptpcamerad`).
- [ ] **Step 4:** Repeat steps 2–3 with Preview and Image Capture open, and
  with Google Drive running if it is installed.
- [ ] **Step 5:** Write the spike doc with a table of condition → result,
  and a final line `Decision: step 1 | step 2 | step 3`. Step 1 means it just
  works. Step 2 means a user-level pause works. Step 3 means sudo is needed.
  Commit with `docs: record ptpcamerad spike result`.

---

### Task 1: Package skeleton, tooling and DeviceKit value types

**Files:**
- Create: `Package.swift`, `Makefile`, `.swiftlint.yml`, `.swift-format`,
  `.gitignore`, `LICENSE` (MIT, 2026, Kris Armstrong), `README.md` (one
  paragraph plus build steps)
- Create: `Sources/DeviceKit/Identifiers.swift`, `Sources/DeviceKit/RemotePath.swift`,
  `Sources/DeviceKit/Models.swift`, `Sources/DeviceKit/TransportError.swift`
- Create: `.github/workflows/ci.yml` (macos-26 runner: brew install libmtp
  swiftlint; `make lint fmt-check test`)
- Test: `Tests/DeviceKitTests/RemotePathTests.swift`

**Interfaces — Produces:**
```swift
public struct DeviceID: Hashable, Sendable, Codable { public let serial: String }
public struct StorageID: Hashable, Sendable, Codable {
  public let device: DeviceID
  public let key: String          // "<StorageDescription>|<VolumeIdentifier>", stable across reconnects
}
public struct DeviceInfo: Hashable, Sendable, Codable {
  public let id: DeviceID; public let manufacturer: String; public let model: String
}
public struct StorageInfo: Hashable, Sendable, Codable {
  public let id: StorageID; public let description: String
  public let capacity: UInt64; public let free: UInt64
}
public struct RemotePath: Hashable, Sendable, Codable, CustomStringConvertible {
  public static let root: RemotePath
  public let components: [String]              // NFC-normalized
  public init(_ string: String) throws(TransportError)   // "/DCIM/Camera" ; "" or "/" = root
  public func appending(_ name: String) throws(TransportError) -> RemotePath
  public var parent: RemotePath? { get }       // nil for root
  public var name: String? { get }             // nil for root
  public var description: String { get }       // "/DCIM/Camera"
}
public enum ItemKind: Sendable, Codable { case file, folder }
public struct RemoteItem: Hashable, Sendable, Codable {
  public let path: RemotePath; public let kind: ItemKind
  public let size: UInt64; public let modified: Date
}
public struct DeviceCapabilities: OptionSet, Sendable, Codable {
  public static let move, copy, partialRead: DeviceCapabilities
}
public enum TransportError: Error, Equatable, Sendable {
  case deviceNotFound(DeviceID), deviceBusy, deviceLocked, deviceDisconnected
  case notFound(RemotePath), alreadyExists(RemotePath), invalidName(String)
  case unsupported(String), insufficientSpace(needed: UInt64, free: UInt64)
  case fileTooLargeForStorage(size: UInt64), sizeMismatch(expected: UInt64, actual: UInt64)
  case cancelled, io(String)
}
```

- [ ] **Step 1: Write the package and tooling.** In `Package.swift`, use tools
  6.4 and `.macOS(.v26)`. Define the products and targets: `DeviceKit`
  (library), `DeviceKitTestSupport` (library, depends on DeviceKit),
  `CLibMTP` (systemLibrary, `pkgConfig: "libmtp"`,
  `providers: [.brew(["libmtp"])]`), `MTPTransport`, and `ferryctl`
  (executable, depends on
  `.package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")`).
  Test targets are `DeviceKitTests` and `MTPTransportTests`. Leave targets
  empty that later tasks fill.
  The Makefile exports `DEVELOPER_DIR` and has these targets:
  - `lint`: `swiftlint --strict`
  - `fmt`: `xcrun swift-format format -i -r Sources Tests`
  - `fmt-check`: `xcrun swift-format lint --strict -r Sources Tests`
  - `test`: `swift test`
  - `build`: `swift build -c release`
- [ ] **Step 2: Write the failing tests** in `RemotePathTests.swift`:
  - `parsesAndPrints`: `try RemotePath("/DCIM/Camera").components == ["DCIM","Camera"]`
    and `.description == "/DCIM/Camera"`.
  - `rootForms`: `RemotePath("")` and `RemotePath("/")` both equal `.root`;
    `.root.parent == nil`.
  - `rejectsBadComponents`: `"/a/../b"`, `"/a/./b"` and `"/a//b"` each throw
    `.invalidName`, and so does `appending("x/y")`.
  - `remotePathNormalizesToNFC`: `try RemotePath("/caf\u{0065}\u{0301}") == try RemotePath("/caf\u{00E9}")`,
    and its components equal `["caf\u{00E9}"]`.
  - `codableRoundTrip`: JSON encode/decode of a `RemotePath` and a
    `RemoteItem` with `size: 5_000_000_000` round-trip unchanged.
- [ ] **Step 3:** Run `make test`. Expect it to FAIL because the types are not
  defined.
- [ ] **Step 4:** Implement the types in the four DeviceKit files, using
  `precomposedStringWithCanonicalMapping` for NFC.
- [ ] **Step 5:** Run `make test lint fmt-check`. Expect all to pass with zero
  warnings.
- [ ] **Step 6:** Commit with `git add -A && git commit -m "feat: add package skeleton and DeviceKit types"`.

---

### Task 2: Transport protocols and FakeTransport

**Files:**
- Create: `Sources/DeviceKit/DeviceTransport.swift`
- Create: `Sources/DeviceKitTestSupport/FakeTransport.swift`
- Test: `Tests/DeviceKitTests/FakeTransportTests.swift`

**Interfaces — Consumes:** Task 1 types. **Produces:**
```swift
public typealias ProgressHandler = @Sendable (_ done: UInt64, _ total: UInt64) -> Bool // return false = cancel
public protocol DeviceTransport: Sendable {
  func connectedDevices() async throws(TransportError) -> [DeviceInfo]
  func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession
}
public protocol DeviceSession: Sendable {
  var info: DeviceInfo { get }
  func capabilities() async -> DeviceCapabilities
  func storages() async throws(TransportError) -> [StorageInfo]          // empty from device ⇒ throws .deviceLocked
  func list(_ folder: RemotePath, in storage: StorageID) async throws(TransportError) -> [RemoteItem]
  func item(at path: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  func download(_ path: RemotePath, in storage: StorageID, to file: URL, progress: ProgressHandler) async throws(TransportError)
  func upload(from file: URL, to path: RemotePath, in storage: StorageID, progress: ProgressHandler) async throws(TransportError) -> RemoteItem  // path must not exist
  func makeFolder(_ path: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  func rename(_ path: RemotePath, to newName: String, in storage: StorageID) async throws(TransportError) -> RemoteItem
  func move(_ path: RemotePath, toFolder: RemotePath, in storage: StorageID) async throws(TransportError) -> RemoteItem
  func delete(_ path: RemotePath, in storage: StorageID) async throws(TransportError)   // folders: recursive
  func close() async
}
// DeviceKitTestSupport
public actor FakeTransport: DeviceTransport { public init(devices: [FakeDevice]) }
public actor FakeDevice: DeviceSession {
  public init(info: DeviceInfo, storages: [StorageInfo], capabilities: DeviceCapabilities = [.move, .copy])
  public func seed(_ path: RemotePath, in: StorageID, contents: Data) throws(TransportError)  // creates parents
  public func setLocked(_ locked: Bool)
  public func failUpload(afterBytes: UInt64, with error: TransportError)  // next upload stores a partial object, then throws
  public func truncateUploads(to bytes: UInt64?)                          // device "keeps" only N bytes, no error
  public func failRename(with error: TransportError?)
  public func contents(of path: RemotePath, in: StorageID) -> Data?
  public func allPaths(in: StorageID) -> [RemotePath]
}
```

- [ ] **Step 1: Write the failing tests** in `FakeTransportTests.swift`:
  - `seedListAndItem`: after `seed("/DCIM/a.jpg")`, `list(.root)` returns one
    folder `DCIM`, and `list("/DCIM")` returns `a.jpg` with the seeded size.
  - `uploadRejectsExisting`: upload to an existing path throws
    `.alreadyExists`.
  - `fakeLockedDeviceThrowsDeviceLocked`: `setLocked(true)` then `storages()`
    throws `.deviceLocked`.
  - `failUploadLeavesPartialObject`: `failUpload(afterBytes: 3, with: .deviceDisconnected)`.
    Upload throws `.deviceDisconnected`, and `allPaths` still contains the
    target path with 3 bytes.
  - `capabilityWithoutMoveThrowsUnsupported`: a device created with `[]`
    throws `.unsupported` from `move`.
- [ ] **Step 2:** Run `swift test --filter FakeTransportTests`. Expect it to
  FAIL to compile.
- [ ] **Step 3:** Implement the protocols and the fakes. The fake keeps a
  dictionary of `[StorageID: [RemotePath: Node]]` in memory.
- [ ] **Step 4:** Run `make test lint fmt-check`. Expect everything to pass.
- [ ] **Step 5:** Commit with `feat: add DeviceTransport protocols and FakeTransport`.

---

### Task 3: SafeWriter (write-safety contract)

**Files:**
- Create: `Sources/DeviceKit/SafeWriter.swift`
- Test: `Tests/DeviceKitTests/SafeWriterTests.swift`

**Interfaces — Consumes:** `DeviceSession`, `FakeDevice`. **Produces:**
```swift
public struct SafeWriter: Sendable {
  public static let partialPrefix = ".ferry-partial-"
  public static func isPartial(_ name: String) -> Bool
  public init(session: any DeviceSession)
  /// Upload `file` to `path`. If `replacing`, an existing file at `path` is replaced; otherwise `.alreadyExists`.
  public func write(from file: URL, to path: RemotePath, in storage: StorageID,
                    replacing: Bool, progress: ProgressHandler) async throws(TransportError) -> RemoteItem
  /// `list` that hides partials and deletes them (best effort, errors logged, not thrown).
  public func visibleList(_ folder: RemotePath, in storage: StorageID) async throws(TransportError) -> [RemoteItem]
}
```

`write` algorithm (spec's write-safety decision, verbatim order):
1. Check free space. If `size > storage.free`, throw `.insufficientSpace`.
2. Upload to `<parent>/.ferry-partial-<UUID>`. On failure, try to delete the
   partial, then rethrow. If `size > UInt64(UInt32.max)` and the error is
   `.io`, throw `.fileTooLargeForStorage(size:)` instead.
3. If the uploaded size differs from the local size, delete the partial and
   throw `.sizeMismatch`.
4. If `replacing` and the target exists, delete the target.
5. Rename the partial to the final name. If the rename fails, delete the
   partial and upload directly to the final name. Re-check the size as in
   step 3, and surface any error from this fallback.

- [ ] **Step 1: Write the failing tests** in `SafeWriterTests.swift`, all
  against `FakeDevice`:
  - `writesViaTempThenRenames`: after the write, the final path holds the
    bytes and no `isPartial` name remains.
  - `disconnectMidUploadLeavesNoFinalName`: with
    `failUpload(afterBytes: 2, with: .deviceDisconnected)`, the write throws
    `.deviceDisconnected`, the final path is absent, and no partial remains
    because the cleanup succeeded.
  - `listingHidesAndDeletesPartials`: seed `/a.txt` and
    `/.ferry-partial-X`. `visibleList(.root)` returns only `a.txt`, and the
    partial is gone from `allPaths`.
  - `shortWriteThrowsSizeMismatchAndCleansUp`: with `truncateUploads(to: 1)`,
    the write throws `.sizeMismatch(expected: 4, actual: 1)` and nothing is
    left behind.
  - `oversizeRejectionMapsToTooLarge`: use a sparse local file of
    `4_294_967_296` bytes (`FileHandle.truncate(atOffset:)`) and
    `failUpload(afterBytes: 0, with: .io("rejected"))`. Expect
    `.fileTooLargeForStorage(size: 4_294_967_296)`.
  - `insufficientSpaceRejectedBeforeUpload`: with storage free `= 2` and a
    4-byte file, expect `.insufficientSpace(needed: 4, free: 2)` and no
    partial created.
  - `replacingDeletesOldThenRenames` and `notReplacingThrowsAlreadyExists`.
  - `renameFailureFallsBackToDirectUpload`: with
    `failRename(with: .unsupported("rename"))`, the final file has the bytes and
    no partial remains.
  - `uploadOverNFDNameReplacesExisting`: seed `"/caf\u{00E9}.txt"`, then
    write to `RemotePath("/caf\u{0065}\u{0301}.txt")` with `replacing: true`.
    Expect exactly one item in the folder.
- [ ] **Step 2:** Run `swift test --filter SafeWriterTests`. Expect it to FAIL.
- [ ] **Step 3:** Implement `SafeWriter` following the algorithm above.
- [ ] **Step 4:** Run `make test lint fmt-check`. Expect everything to pass.
- [ ] **Step 5:** Commit with `feat: add SafeWriter write-safety contract`.

---

### Task 4: libmtp binding and MTP session actor

**Files:**
- Create: `Sources/CLibMTP/module.modulemap`
  (`module CLibMTP [system] { header "shim.h"  link "mtp"  export * }`),
  `Sources/CLibMTP/shim.h` (`#include <libmtp.h>`)
- Create: `Sources/MTPTransport/PathResolver.swift`, `Sources/MTPTransport/MTPDevice.swift`,
  `Sources/MTPTransport/MTPErrors.swift`
- Test: `Tests/MTPTransportTests/PathResolverTests.swift`,
  `Tests/MTPTransportTests/MTPDeviceIntegrationTests.swift`

**Interfaces — Produces:**
```swift
struct RawDeviceRef: @unchecked Sendable { let raw: LIBMTP_raw_device_t }  // copied out of the Detect array, which is then freed
struct MTPEntry: Sendable, Equatable { let objectID: UInt32; let name: String; let isFolder: Bool; let size: UInt64; let modified: Date }
/// Caches folder listings and resolves storage-relative paths to object IDs.
actor PathResolver {
  static let rootParent: UInt32 = 0xFFFF_FFFF    // LIBMTP_FILES_AND_FOLDERS_ROOT
  init(lister: @escaping @Sendable (_ storage: UInt32, _ parent: UInt32) async throws(TransportError) -> [MTPEntry])
  func objectID(for path: RemotePath, storage: UInt32) async throws(TransportError) -> UInt32   // root → rootParent
  func entries(in folder: RemotePath, storage: UInt32) async throws(TransportError) -> [MTPEntry]
  func invalidate(_ folder: RemotePath, storage: UInt32)
  func invalidateAll()
}
/// Owns one libmtp device handle; every call runs on its own serial queue.
actor MTPDevice {
  nonisolated var unownedExecutor: UnownedSerialExecutor   // backed by a DispatchSerialQueue
  static func detect() throws(TransportError) -> [RawDeviceRef]   // LIBMTP_Detect_Raw_Devices
  init(opening raw: RawDeviceRef) throws(TransportError)          // LIBMTP_Open_Raw_Device_Uncached; failure ⇒ .deviceBusy
  var info: DeviceInfo { get }                                    // serial via LIBMTP_Get_Serialnumber
  func capabilities() -> DeviceCapabilities                       // LIBMTP_Check_Capability: MoveObject, CopyObject, GetPartialObject
  func storages() throws(TransportError) -> [(raw: UInt32, info: StorageInfo)]  // LIBMTP_Get_Storage(SORTBY_NOTSORTED); empty ⇒ .deviceLocked
  func list(storage: UInt32, parent: UInt32) throws(TransportError) -> [MTPEntry]   // LIBMTP_Get_Files_And_Folders
  func download(objectID: UInt32, to: URL, progress: ProgressHandler) throws(TransportError)       // LIBMTP_Get_File_To_File
  func upload(from: URL, name: String, parent: UInt32, storage: UInt32, progress: ProgressHandler) throws(TransportError) -> UInt32  // LIBMTP_Send_File_From_File
  func createFolder(name: String, parent: UInt32, storage: UInt32) throws(TransportError) -> UInt32 // LIBMTP_Create_Folder
  func rename(objectID: UInt32, to: String) throws(TransportError)       // Get_Filemetadata + Set_File_Name
  func move(objectID: UInt32, storage: UInt32, newParent: UInt32) throws(TransportError)  // LIBMTP_Move_Object
  func delete(objectID: UInt32) throws(TransportError)                   // LIBMTP_Delete_Object
  func metadata(objectID: UInt32) throws(TransportError) -> MTPEntry
  isolated deinit                                                        // LIBMTP_Release_Device
}
```
Error mapping in `MTPErrors.swift`: drain `LIBMTP_Get_Errorstack` into the
`.io` message, then `LIBMTP_Clear_Errorstack`. `LIBMTP_ERROR_NO_DEVICE_ATTACHED`
and USB errors after open map to `.deviceDisconnected`. A progress callback
returning false maps to `.cancelled`. The progress trampoline passes the Swift
closure as `Unmanaged` context data and returns non-zero to cancel.
`LIBMTP_Init()` is called once from a `static let` initializer.

- [ ] **Step 1: Write the failing `PathResolverTests`**, using a stub lister
  that counts calls:
  - `resolvesNestedPath`: `/DCIM/Camera` resolves to the expected ID by
    listing root, then the `DCIM` ID.
  - `cachesListings`: resolving the same path twice calls the lister twice
    in total, not four times.
  - `invalidateForcesRelist`.
  - `missingComponentThrowsNotFound`: expect `.notFound(path)`.
  - `duplicateNamesResolveToLowestID`: two entries named `a` with IDs 9 and 4
    resolve to 4.
  - `namesMatchNFC`: an entry named in NFD resolves from an NFC
    `RemotePath`.
- [ ] **Step 2:** Run `swift test --filter PathResolverTests`. Expect it to FAIL.
- [ ] **Step 3:** Implement `PathResolver`, then `MTPDevice` and
  `MTPErrors` against the libmtp calls named above.
- [ ] **Step 4:** Write `MTPDeviceIntegrationTests`, gated with
  `.enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_TESTS"] == "1")`.
  Tests:
  - `detectsAndOpens`
  - `storagesEmptyMapsToLocked`: manual, run with the phone locked; gate it
    with `FERRY_DEVICE_LOCKED=1`.
  - `roundTripSmallFile`: create a folder `ferry-test-<uuid>` at root, upload
    16 bytes, list it, download and compare, rename, then delete the folder.
- [ ] **Step 5:** Run `make test`. Expect it to pass, with the integration
  tests skipped. Then, with a phone attached, run
  `FERRY_DEVICE_TESTS=1 swift test --filter MTPDeviceIntegrationTests`.
  Expect it to pass. Record the device model and Android version in the
  commit body.
- [ ] **Step 6:** Commit with `feat: add libmtp binding, MTPDevice and PathResolver`.

---

### Task 5: MTPTransport (DeviceTransport over libmtp)

**Files:**
- Create: `Sources/MTPTransport/MTPTransport.swift`, `Sources/MTPTransport/MTPSession.swift`
- Test: `Tests/MTPTransportTests/MTPSessionIntegrationTests.swift`

**Interfaces — Consumes:** Task 2 protocols, Task 4 `MTPDevice` and
`PathResolver`. **Produces:**
```swift
public struct MTPTransport: DeviceTransport { public init() }
actor MTPSession: DeviceSession   // StorageID.key ↔ raw storage id map refreshed by storages(); every mutation invalidates the affected folder(s)
```
Rules:
- Find a storage by `StorageID.key`, never by its raw ID.
- `move` without the `.move` capability is copy+delete for files (download to
  a temp file, upload, delete). Folders throw `.unsupported("move")`.
- `delete` on a folder deletes its children depth-first.
- `upload` to an existing name throws `.alreadyExists`. Check the resolver
  first.
- Every name sent to the device is NFC.

- [ ] **Step 1:** Write `MTPSessionIntegrationTests`, gated by
  `FERRY_DEVICE_TESTS=1`:
  - `fullRoundTripThroughSafeWriter`: `SafeWriter` writes 1 MB into a temp
    folder; check `visibleList`, `item`, `download`, `rename`, `move` to a
    subfolder and recursive `delete`.
  - `largeFileOver4GB`: gated by `FERRY_LARGE_FILE_TESTS=1`; a 4.1 GB sparse
    file to internal storage succeeds with the size preserved.
  - `storageKeysStableAcrossReopen`: close, reopen, and the `StorageID`s are
    equal.
- [ ] **Step 2:** Run `FERRY_DEVICE_TESTS=1 swift test --filter MTPSessionIntegrationTests`.
  Expect it to FAIL to compile.
- [ ] **Step 3:** Implement `MTPTransport` and `MTPSession`.
- [ ] **Step 4:** Run `make test lint fmt-check`. Expect it to pass. Run the
  device suite above and expect it to pass. Also run it on an Android 8/9
  phone if one is available, and record the results in `docs/TESTING.md`
  (create the file with a device/Android/result table).
- [ ] **Step 5:** Commit with `feat: add MTPTransport`.

---

### Task 6: `ferryctl` CLI

**Files:**
- Create: `Sources/ferryctl/Ferryctl.swift` (root `AsyncParsableCommand`),
  `Sources/ferryctl/Commands.swift`

**Interfaces — Consumes:** `MTPTransport`, `SafeWriter`. Commands, with the
device being the first found when `--device <serial>` is omitted:
`devices`, `storages`, `ls <path> [--storage <description>]`,
`get <remote> <local>`, `put <local> <remote> [--replace]`, `mkdir <path>`,
`mv <path> <folder>`, `rename <path> <name>`, `rm <path>`. `put` must go
through `SafeWriter`, and `ls` through `visibleList`. Errors print one line
to stderr and exit 1. `.deviceBusy` prints
`Another app is using the phone (Image Capture, Preview, Photos or a sync app). Quit it and replug, or see docs/spikes/2026-11-ptpcamerad.md.`
`.deviceLocked` prints `Unlock your phone and choose "File transfer".`

- [ ] **Step 1:** Implement the commands. This is a thin layer with no
  logic of its own, so it has no unit tests.
- [ ] **Step 2:** Run `make build`. Expect it to succeed with zero warnings.
- [ ] **Step 3:** Manual smoke test with a phone:
  `swift run ferryctl devices`, `ls /`, `put README.md /Download/ferry-smoke.md`,
  `get /Download/ferry-smoke.md /tmp/x.md && diff README.md /tmp/x.md`, and
  `rm /Download/ferry-smoke.md`. Expect each to succeed. With the phone
  locked, expect the unlock message.
- [ ] **Step 4:** Add a usage section to `README.md` and commit with
  `feat: add ferryctl CLI`.

---

## Plans 2 and 3 (written after this plan lands)

- **Plan 2 — Finder integration:** the XcodeGen app, an `SMAppService` agent
  with its XPC Mach service, `FerryIPC`, the FileProvider replicated extension
  with domains per `StorageID`, and the SwiftUI `MenuBarExtra`. The Task 0
  outcome decides the phone-grab UX there, including the privileged helper if
  step 3 is needed.
- **Plan 3 — Release:** build libusb and libmtp from pinned source in CI, sign
  with Developer ID and notarize, make the DMG, the Homebrew cask, and LGPL
  notices. It also needs the owner's App ID, app group and provisioning
  profile.

### Plan 2 entry rows (from the final review of this plan)

These must be done or decided before Plan 2's agent ships.

- **Operation gate and fresh existence checks.** Each session gets a gate so
  that one operation finishes before the next starts, with no actor
  reentrancy across awaits. The parent listing is invalidated before every
  existence check. `list()` treats a partially failed listing as a failure,
  never as a shorter result.
- **Move fallback partials in the registry.** The partial that
  `copyThenDelete` uploads is registered in SafeWriter's in-flight registry,
  so a concurrent `visibleList` cannot reap it.
- **Fail fast after a disconnect.** A device that reports `.deviceDisconnected`
  releases its libmtp handle, so later calls fail at once instead of timing
  out on USB.
- **`DeviceSession.download` gains `replacing:`.** When it is false, the
  partial is moved into place with `renamex_np(RENAME_EXCL)`, which closes
  the race between `get`'s existence check and the rename.
- **Process-wide registry of held devices.** A device this process already
  holds is not reported as `.deviceBusy` when it is opened again.
- **Replace order (owner decision, open).** Today a replacing write deletes
  the old file and then renames the partial over its name. The alternative is
  to rename the old file aside first, so a failed rename can restore it.
- **Private file names in logs.** Every file name logged with
  `privacy: .public` becomes private before the agent ships.
