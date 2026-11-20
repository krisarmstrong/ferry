# Ferry Native ADB Engine Implementation Plan

> **Shelved 2026-11-20 (owner).** Ferry bundles adb inside Ferry.app instead (plan 2026-11-18 Task 22). This plan stays as the route back if a real need for an adb-free engine appears.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ferry speaks ADB to Android devices itself, over USB, plain TCP and (Android 11+) TLS, so every ADB feature works with no `adb` installed and no adb server running, while a server the user started keeps working beside it.

**Architecture:** `ADBTransport` keeps everything above the connection and gains two protocols, `ADBByteStream` (a service's byte pipe) and `ADBConnector` (device table, `open(route, service)`, features, forwards). Today's host-protocol client becomes `ServerConnector`; a new `ADBNative` module provides `NativeConnector` (CNXN/AUTH/STLS, stream multiplexing over a packet-level `ADBLink`: USB via IOUSBHost, TCP and TLS via Network.framework). A `RoutingConnector` serves each device through exactly one side, and every route names its side. Sync, shell, logcat, the `inotifyd` watch, tools, `ADBSession`, `DeviceHub`, `CompositeTransport` and the IPC for files are unchanged.

**Tech Stack:** Swift 6 (strict concurrency, actors), IOUSBHost, IOKit, Network.framework (`NWConnection`, `NWListener`, `NWBrowser`, `NWProtocolTLS`, `NWProtocolFramer`), Security.framework (Keychain, `SecKey`, `SecIdentity`), CryptoKit (HKDF, AES-GCM, SHA-256), vendored BoringSSL (SPAKE2 only, P4), Swift Testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-19-ferry-native-adb-design.md`, including "Owner decisions (2026-11-19)", which bind this plan. Executors read the spec section a task cites before starting it.

**Budget:** 30 working days, hard stop **2027-02-26**. Phases: P0 2 d · P1 8 d · P2 6 d · P3 4 d · P4 9 d · reserve 1 d. Each phase ends with a gate task (live run, kill criterion quoted from the spec). If a kill criterion trips, stop and report to the controller; do not start the next phase.

## Global Constraints

- **Floor:** Android 8.1. Check every protocol choice against `platform/system/core/+/oreo-mr1-release/adb` first, `packages/modules/adb` main second.
- **Host CNXN, verbatim:** `CNXN(0x01000001, 1 MiB, "host::features=shell_v2,cmd,stat_v2,ls_v2")`. Usable features = that list ∩ the device banner's `features=`.
- **Constants (`adb.h`):** `CNXN 0x4e584e43`, `AUTH 0x48545541`, `OPEN 0x4e45504f`, `OKAY 0x59414b4f`, `WRTE 0x45545257`, `CLSE 0x45534c43`, `STLS 0x534C5453`; `A_VERSION 0x01000001`, `A_VERSION_MIN 0x01000000`, `A_VERSION_SKIP_CHECKSUM 0x01000001`, `MAX_PAYLOAD 1 MiB`, `MAX_PAYLOAD_V1 4096`, `TOKEN_SIZE 20`, `A_STLS_VERSION 0x01000000`; AUTH types `TOKEN=1`, `SIGNATURE=2`, `RSAPUBLICKEY=3`; ADB interface `0xFF/0x42/0x01`.
- **Deferred, enforced:** delayed ACK (never advertised, `OPEN` `arg1` always 0), `reverse` (every device-initiated `OPEN` gets `CLSE`), `sendrecv_v2`, QR pairing, the Non-goals list.
- **The user's adb:** from P2 on, Ferry never starts, kills or detaches the user's adb server. Ferry never listens on 5037. Forwards bind `127.0.0.1` only.
- **`~/.android/`:** never written, never created. `~/.android/adbkey` is read only for an AUTH exchange on USB or plain TCP, tried after Ferry's key, held in memory for that exchange only, never used for TLS. `ADB_VENDOR_KEYS` is not read.
- **The ADB key** signs only 20-byte `TOKEN`s, only on an ADB link.
- **No network scan.** Ferry connects only to addresses the user typed, addresses a USB-attached device reported for itself, remembered addresses, and mDNS instances of `_adb-tls-pairing._tcp` / `_adb-tls-connect._tcp`. `_adb._tcp` is never browsed.
- **Apple devices** (vendor `0x05AC`) are never candidates.
- **Agent:** unsandboxed, no new entitlements for USB, no new XPC roles; the FileProvider and Finder Sync extensions never touch the engine.
- **Limits:** at most 64 streams per connection; per-stream buffering at most one effective-maxdata payload; banner ≤ 4096 bytes and UTF-8.
- **Concurrency:** Swift 6 strict concurrency; actors and async/await; no new locks or GCD callbacks where an actor will do (IOKit/IOUSBHost completion handlers bridge into continuations).
- **TDD:** every behaviour change starts with a failing test; paste the RED output (test name plus failure line) into the task report. No sleeps or real-time waits in new tests: injected clocks (`ManualClock`, `TestClock`) and signals. New tests do not use `ADBFixture.eventually`. Every test run is under `timeout`.
- **No suppression comments** (`swiftlint:disable`, `// swift-format-ignore`, `@preconcurrency` added to silence a warning, `nonisolated(unsafe)`). Fix the cause or stop and ask.
- **Copy:** user-visible strings in the String Catalog of the module that shows them. The one exception is `NSLocalNetworkUsageDescription` in the agent's embedded Info.plist, because a bundle-less tool has no catalog (Task 18). No marketing vocabulary. No NetAlly branding in copy beyond the existing allowed sentence.
- **Logging:** `os.Logger`. Serials, addresses, banners, models, GUIDs and key fingerprints are logged `privacy: .private`.
- **Test data:** placeholder serials only (`0123456789abcdef`, `fedcba9876543210`, `R58N12345`), and addresses in 192.0.2.x only, in code, tests, spikes and `docs/TESTING.md`.
- **No NetAlly unlock details**, ever, anywhere in this repo (including spike notes). Live-task prerequisites say only "ADB enabled on the tester". Do not read or cite `internal/`.
- **Pre-1.0:** no compatibility shims or convenience initialisers kept for old call shapes. Delete and migrate every caller in the same task.
- **Done per task:** `timeout 1800 make lint fmt-check test` clean, and `make app` clean for tasks touching `project.yml`, the apps or the agent (accepted warnings: the libmtp/IOKit ones only). Device tests run only with `FERRY_DEVICE_TESTS=1`, never in CI.
- **Modules:** `ADBNative` depends on `ADBTransport`, `DeviceKit`, `USBKit`, never the reverse. A new module or product is added to both `Package.swift` and `project.yml` (FerryAgent lists its products, plus linked SDK frameworks) in the same task.

## Review Focus

1. **A server starts or exits mid-transfer.** The user runs `adb devices` (which starts a server) or `adb kill-server` during a Finder copy. Expect the copy to finish, or to fail cleanly with no visible partial. Ferry does not yield a natively held unit by itself. After a server exits, a server-routed unit is claimed natively on the next scan, with its Finder location and item IDs unchanged. Test in Task 13.
2. **A wedged stream beside a healthy one.** A logcat or `inotifyd` stream whose consumer stops reading, or a device that never answers one `OPEN`, on the same link as a Finder download. Expect the download to finish at full rate and the wedged stream to end on `cancel()` with `.cancelled`, without closing the link. Test in Task 7.
3. **A hostile or broken device.** Oversize `data_length`, bad magic, bad checksum on an 8.1 link, a short `TOKEN`, a device `OPEN`, a second `WRTE` before `OKAY`, a 65th stream, a non-UTF-8 banner. Expect the connection to close (or the frame to be refused) with bounded memory. The agent and other devices are unaffected. Test in Tasks 4, 6, 7.
4. **A stale route.** A replugged unit, a TCP reconnect to an address now held by another unit, or a server `transport_id` that equals a native connection ID. Expect `.deviceGone`, never another unit's data; a route never crosses sides. Test in Tasks 2, 12, 13.
5. **A refused permission or an unreadable key.** Local Network access is denied, or `~/.android/adbkey` is missing, unreadable, not RSA-2048, or a PKCS#1/PKCS#8 variant. Expect the network forms to say how to allow Local Network access; a bad adbkey is skipped without noise, never repaired or written. Test in Tasks 5, 18.

## File Structure

```
Sources/USBKit/                      (new, IOKit only; Task 3)
  USBRegistry.swift                  moved from MTPTransport: attached(), isAttached, registryID, record
  USBDeviceRecord.swift              USBDeviceRecord, USBInterface (+ isADB)
Sources/MTPTransport/USBCandidates.swift   keeps candidacy; MTP-shape props become an extension here
Sources/ADBTransport/                (seam; Tasks 1, 2, 13)
  ADBByteStream.swift                protocol
  ServerStream.swift                 was ADBStream.swift
  ServerConnector.swift              was ADBHost.swift
  ADBConnector.swift                 protocol, ADBDeviceEvent, run/openShell extension
  ADBRoutes.swift                    ADBRoute(serial:via:), ADBVia
  RoutingConnector.swift             (Task 13)
Sources/ADBNative/                   (new; Tasks 4–9, 11–12, 14–15, 17, 19, 22–26)
  ADBMessage.swift  ADBFrameCodec.swift  ADBBanner.swift  ADBLink.swift
  ADBKeys.swift  AndroidPublicKey.swift  ADBKeyFile.swift  KeychainADBKey.swift
  ADBConnection.swift  ADBConnection+Auth.swift  NativeStream.swift
  NativeConnector.swift  NativeForwards.swift  NativeUSB.swift  USBClaimPolicy.swift
  USBLink.swift  USBFraming.swift  TCPLink.swift  NativeWireless.swift  ShellBridge.swift
  TLS/ (P4): TLSLink.swift  STLSFramer.swift (or BoringTLS.swift)  ADBCertificate.swift
             PairingClient.swift  PairingCodec.swift  ADBMDNS.swift  DevicePins.swift
Sources/ADBNativeTestSupport/        (new library, like DeviceKitTestSupport)
  MemoryLink.swift  FakeDeviceWire.swift  EphemeralKey.swift
Sources/CBoringSPAKE/                (P4, vendored, pinned)
scripts/vendor-boringssl.sh          (P4)
Tests/ADBNativeTests/                (new)
Tests/ADBTransportTests/FakeADBDevice.swift  ConnectorBackend.swift   (Task 8)
```

---

## P0 — Spike (2 d)

### Task 0: Spike — native ADB beside libmtp in one process (owner-assisted)

Owner prerequisites: ADB enabled on the tester (LinkRunner 10G or 100G), USB debugging on, the adb server stopped (`adb kill-server`), Ferry's agent quit.

**Files:** Create `docs/spikes/2026-11-native-adb.md` on `feat/adb`. Put the spike code on a throwaway branch `spike/native-adb` (a `ferryctl spike-adb` subcommand that opens the device through `MTPTransport` and then the ADB interface through IOUSBHost in the same process). That branch is never merged; record its final commit SHA in the doc.

- [ ] Answer each, with evidence (command plus output, serials replaced by `0123456789abcdef`, addresses by 192.0.2.x):
  - **O-B5:** does IOUSBHost open `0xFF/0x42/0x01` while libmtp holds the MTP interface in the same process? If not, does libusb (its own context) open it?
  - CNXN → AUTH with a fresh in-memory RSA-2048 key (Allow on the unit), then again with `~/.android/adbkey` (read-only) → `OPEN sync:` → one `STAT /storage/emulated/0`.
  - Record the OUT and IN endpoint descriptor `wMaxPacketSize`, the device banner (model and product replaced if identifying), and its `features=` list.
  - Does the device accept the host banner as exactly the spec's bytes with no trailing NUL? Does its banner end in a NUL?
  - **O-B10:** do `shell,v2`, legacy `shell:`, `exec:` and `sync:` behave with the four-feature host banner as with adb's?
  - **O-B4:** with platform-tools 37.0.1, start the server while the spike holds the interface, release it, and record whether the running server lists the device without a replug.
  - **O-B3:** which hash the "Allow USB debugging?" dialog shows. Compare the dialog's text with MD5 and with SHA-256 of the base64-decoded Android public-key blob.
  - **O-B9:** `adb help 2>&1 | grep -i detach`.
  - **O-B6:** with the agent running from `make app`, confirm no Local Network alert has ever appeared for its 5037 connections. Also run an `NWListener` on 127.0.0.1 from the signed agent build.
  - **O-B2 probe:** from a signed debug build of the agent (`make app`), `SecKeyCreateRandomKey` with `kSecUseDataProtectionKeychain: true`, `kSecAttrAccessGroup` = the agent's existing app group `$(FERRY_TEAM_ID).io.github.krisarmstrong.ferry`, `kSecAttrIsExtractable: false`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, `kSecAttrSynchronizable: false`. Record success or the `OSStatus`; delete the probe key afterwards. The agent is an XcodeGen `type: tool` and cannot embed a provisioning profile, so the profile half of O6 is not available without converting the agent to a bundle (out of scope).
  - **Baseline for the P2 kill criterion:** copy one 5 GB file to the device and back through Ferry's current server path on the same unit and cable. Record MB/s both ways (`time` + file size).
- [ ] End with a `Decision:` line, then one line per follow-on:
  - IOUSBHost, or the libusb fallback. If libusb: Tasks 9 and 12 are amended to a `LibUSBLink` behind the same `ADBLink`, and Task 3 still lands.
  - Keychain: data-protection with the app group, or the login keychain with an ACL to the agent's designated requirement (Task 11 implements only the one chosen).
  - Fingerprint hash for Task 11.
  - Host banner NUL handling for Task 4.
  - O-B4 outcome for Task 15's help text.
- [ ] **Gate (kill criterion, spec §11 P0):** "neither IOUSBHost nor libusb can hold the ADB interface while libmtp holds MTP in the same process, and serving ADB-only (MTP closed) is unacceptable to the owner. Then stop; external adb stays." If neither opens it, stop and report to the controller with the evidence; the owner decides whether ADB-only is acceptable.
- [ ] Shippable state: no product change. Commit `docs: record native ADB spike`.

---

## P1 — Engine core (8 d)

### Task 1: `ADBByteStream` and `ServerStream`

**Files:** Create `Sources/ADBTransport/ADBByteStream.swift`. Rename `ADBStream.swift` → `ServerStream.swift` (`actor ADBStream` → `actor ServerStream`). Modify every holder of `ADBStream`: `ADBSync.swift`, `ADBShell.swift`, `ADBShellOutput.swift`, `ADBLogcat.swift`, `ADBSession+Watch.swift` (`WatchConnections` keys by `ObjectIdentifier`), `ADBDeviceTools.swift`, `ADBWireless.swift`. Tests: `FakeADBServer.swift` (`Peer.stream`), `FakeAndroid+Server.swift`, `ADBSessionFixture.swift` (`serial` → `"192.0.2.5:5555"`).

**Interfaces — Produces:**
```swift
public protocol ADBByteStream: AnyObject, Sendable {
  func read(exactly count: Int) async throws(ADBError) -> Data
  /// At most `count` bytes, or nil once the peer has closed cleanly.
  func readSome(upTo count: Int) async throws(ADBError) -> Data?
  func write(_ data: Data) async throws(ADBError)
  func close() async
  /// Ends the stream at once without waiting on its actor; a blocked read fails.
  func cancel()   // `nonisolated` in actor conformers
}
```
- `ServerStream: ADBByteStream` keeps `open(port:timeout:)`, `connect(until:_:)`, `settle`, `expectOkay()`, `readFrame()` (host protocol only, internal).
- `ADBSync.init(stream: any ADBByteStream, features:)`, `ADBLogcat.init(stream: any ADBByteStream, …)`, `ADBShellOutput.init(stream: any ADBByteStream, token:)`.
- `FakeADBServer.Peer.stream: any ADBByteStream`. `Peer`'s helpers use only the five members, so the same handlers can later run over an in-memory stream.

- [ ] Tests: no new behaviour. Every existing test passes unchanged except for the type rename and the fixture serial. Add `readSomeIsReachableThroughTheProtocol`: an `ADBSync` built from `any ADBByteStream` over a `ServerStream` lists a fake folder; asserts the entry names.
- [ ] Commit `refactor(adb): service streams behind ADBByteStream`.

### Task 2: Routes name their side; `ADBConnector`; `ServerConnector`

**Files:** Modify `ADBRoutes.swift`, `ADBWire.swift` (`ADBDevice`), `ADBTransport.swift`, `ADBTransport+Transports.swift`, `ADBTransport+Reading.swift` (`Listing`, `info(of:)`, `property(…)`), `ADBSession.swift` (+ `+Watch`, `+Read`, `+Write`, `+Delete`, `+Names`), `ADBShell.swift`, `ADBForwards.swift`, `ADBDeviceTools.swift`, `ADBWireless.swift`, `ADBStorages.swift`. Rename `ADBHost.swift` → `ServerConnector.swift`. Create `ADBConnector.swift`. In FerryAgentCore: `WirelessADB.swift` (`WirelessADBControl`), `WirelessADB+Connecting.swift`, `ADBTools*.swift`, `ToolJournal.swift`, `AgentService+Tools.swift`. In FerryIPC: `Tools.swift` (`ShellTarget.transportID` stays a server-only `String?` until Task 16). Tests: all `ADBTransportTests`, `FakeWirelessADB.swift`, `FakeToolDevice.swift`, and any FerryAgentCoreTests building `ADBRoute`.

**Interfaces — Produces:**
```swift
public enum ADBVia: Sendable, Hashable {
  case server(transportID: String?)   // adb's transport_id, when it reports one
  case native(connection: UInt64)
}
public struct ADBRoute: Sendable, Hashable { public let serial: String; public let via: ADBVia
  public init(serial: String, via: ADBVia) }
// ADBDevice: `transportID: String?` is replaced by `via: ADBVia`.
public enum ADBDeviceEvent: Sendable, Equatable { case devices([ADBDevice]); case unavailable }
public protocol ADBConnector: Sendable {
  func devices() async throws(ADBError) -> [ADBDevice]
  /// A new list per change; `.unavailable` once per outage (server side only).
  func deviceEvents() -> AsyncStream<ADBDeviceEvent>
  func features(_ route: ADBRoute) async throws(ADBError) -> Set<String>
  func open(_ route: ADBRoute, service: String) async throws(ADBError) -> any ADBByteStream
  func forwards(route: ADBRoute) async throws(ADBError) -> [PortForward]
  func addForward(route: ADBRoute, _ forward: PortForward) async throws(ADBError)
  func removeForward(route: ADBRoute, local: UInt16) async throws(ADBError)
}
extension ADBConnector {
  public func run(route: ADBRoute, command: String, features: Set<String>? = nil)
    async throws(ADBError) -> ADBShellResult
  func openShell(route: ADBRoute, command: String, token: String, features: Set<String>?)
    async throws(ADBError) -> (stream: any ADBByteStream, token: String?)
}
public actor ServerConnector: ADBConnector   // today's ADBHost; keeps version(), query(_:),
                                             // startServer() and the locator until Tasks 13/19
```
- `ADBSession.init(connector: any ADBConnector, route: ADBRoute, info:features:method:partials:onRelease:)`. `ADBDeviceTools.init(connector: any ADBConnector)`. `ADBTransport.init(connector: any ADBConnector, …)`. `ADBTransport.Held.via: ADBVia?` replaces `transportID`, and `transportIDs: [String: String]` becomes `vias: [String: ADBVia]`. `ADBServerEvent` is renamed `ADBDeviceEvent`.
- `ServerConnector` opens a route `.server(nil)` by `host:transport:<serial>`, `.server(id)` by `host:transport-id:<id>`, and throws `.deviceGone(serial)` for a `.native` route without touching the socket.
- `WirelessADBControl`'s `device(at:)`, `tcpPort(of:)`, `networkAddresses(of:)` and `restartInTCPMode(_:port:)` take an `ADBRoute` instead of an adb serial. `trackServer()` becomes `deviceEvents() -> AsyncStream<ADBDeviceEvent>`.

- [ ] Tests (RED first where behaviour is new):
  - `serverRouteWithIDSelectsByTransportID`: the fake server sees `host:transport-id:7` for `.server(transportID: "7")`.
  - `nativeRouteOnServerIsGone`: `open(ADBRoute(serial: "S", via: .native(connection: 7)), service: "sync:")` on `ServerConnector` throws `.deviceGone("S")`, and the fake server records no connection.
  - `routesDifferingOnlyInSideAreDistinct`: `.server(transportID: "7")` and `.native(connection: 7)` with the same serial are `!=` and hash to separate `Set` members.
  - `noteTransportsDropsRouteWhenSideChanges`: a held route whose serial is re-listed with another `via` has its tool route dropped (extend `ADBTransportPinningTests`).
  - All existing tests are migrated to routes and pass.
- [ ] Commit `refactor(adb): routes name their connector; ADBConnector seam`.

### Task 3: `USBKit` — the registry outside MTP

**Files:** Create `Sources/USBKit/USBRegistry.swift`, `USBDeviceRecord.swift` (moved from `MTPTransport/USBRegistry.swift`, `USBCandidates.swift`). Modify `MTPTransport/USBCandidates.swift` (keeps `USBCandidacy`, `USBCandidates`; `looksLikeMTP`, `isStillImage`, `isVendorSpecific`, `announcesMTP` become an `extension USBInterface` here), `MTPTransport.swift`, `MTPDevice.swift`, `DeviceRegistry.swift`, `FerryAgentCore/USBWatcher.swift`. `Package.swift`: target `USBKit` (deps `DeviceKit`), product, `MTPTransport` and `FerryAgentCore` depend on it. `project.yml`: FerryAgent adds product `USBKit`. Tests: `Tests/MTPTransportTests` (moved record tests import `USBKit`), new `Tests/USBKitTests/` target.

**Interfaces — Produces:**
- `public enum USBRegistry { public static func attached() throws(TransportError) -> [USBDeviceRecord]; public static func isAttached(registryID: UInt64) -> Bool; public static func registryID(of: io_service_t) -> UInt64?; public static func record(of: io_service_t) -> USBDeviceRecord? }`. The module is `USBKit`, so the type name does not clash with it.
- `USBInterface` gains `public let interfaceNumber: UInt8` (read from `bInterfaceNumber`) and `public var isADB: Bool { interfaceClass == 0xFF && subclass == 0x42 && interfaceProtocol == 0x01 && endpoints == 2 && !hasDriver }`.
- `USBDeviceRecord.adbInterface: USBInterface?` returns the first `isADB` interface, or `nil` when `vendorID == 0x05AC`.
- `MTPTransport` gains `public static func isCandidate(_ device: USBDeviceRecord) -> Bool` (`candidacy(of:) != .ignored`); `USBCandidacy` stays internal.
- `candidateDevice(_:)` moves to `USBWatcher` (FerryAgentCore): a device is a candidate if `MTPTransport.isCandidate(record)` **or** `record.adbInterface != nil`.

- [ ] Tests:
  - `adbInterfaceMatchesOnlyFF4201WithTwoEndpoints`: `FF/42/01/2` → true; `FF/42/01/3`, `FF/FF/00/3`, `FF/42/00/2`, and `FF/42/01/2` with `hasDriver` → false.
  - `appleDeviceHasNoADBInterface`: vendor `0x05AC` with `FF/42/01/2` → `adbInterface == nil`.
  - `chargingWithDebuggingIsAWatcherCandidate`: `0x18D1/0x4EE7` with one `FF/42/01/2` interface is a candidate.
  - The existing `USBCandidates` table tests pass unchanged.
- [ ] Commit `refactor(usb): registry reading in its own module`.

### Task 4: `ADBNative` wire layer

**Files:** Create `Sources/ADBNative/ADBMessage.swift`, `ADBFrameCodec.swift`, `ADBBanner.swift`, `ADBLink.swift`; `Sources/ADBNativeTestSupport/MemoryLink.swift`; `Tests/ADBNativeTests/ADBFrameCodecTests.swift`, `ADBBannerTests.swift`, `ADBWireFuzzTests.swift`. `Package.swift`: targets `ADBNative` (deps `ADBTransport`, `DeviceKit`, `USBKit`), `ADBNativeTestSupport` (deps `ADBNative`), test target `ADBNativeTests`. Add products. `project.yml`: FerryAgent adds `ADBNative`, plus SDK frameworks `IOUSBHost.framework` and `Network.framework`.

**Interfaces — Produces:**
```swift
public enum ADBCommandWord: UInt32, Sendable { case cnxn = 0x4e584e43, auth = 0x48545541,
  open = 0x4e45504f, okay = 0x59414b4f, wrte = 0x45545257, clse = 0x45534c43, stls = 0x534C5453 }
public struct ADBMessage: Sendable, Equatable {
  public var command: ADBCommandWord; public var arg0: UInt32; public var arg1: UInt32
  public var payload: Data }
public struct ADBHeader: Sendable, Equatable { command, arg0, arg1, dataLength, dataCheck, magic: UInt32 }
public struct ADBLimits: Sendable, Equatable {
  public var maxData: UInt32          // our 1 MiB before the device's CNXN, effective after
  public var verifiesChecksum: Bool   // true while effective version == 0x01000000
  public static let beforeConnect: ADBLimits   // maxData 1 << 20, verifiesChecksum true
}
public enum ADBWireError: Error, Equatable, Sendable {
  case badMagic, oversize(UInt32), unknownCommand(UInt32), badChecksum, zeroStreamID,
       badOkayPayload, badTokenLength, badBanner }
public enum ADBFrameCodec {
  public static func checksum(_ payload: Data) -> UInt32          // wrapping byte sum
  public static func encodeHeader(_ message: ADBMessage) -> Data  // 24 bytes, checksum always filled
  public static func decodeHeader(_ bytes: Data, limits: ADBLimits) throws(ADBWireError) -> ADBHeader
  public static func message(_ header: ADBHeader, payload: Data, limits: ADBLimits)
    throws(ADBWireError) -> ADBMessage
}
public struct ADBBanner: Sendable, Equatable {
  public let systemType: String; public let serial: String
  public let properties: [String: String]; public let features: Set<String>
  public static func host(features: [String]) -> Data   // "host::features=" + joined by ","
  public static func parse(_ payload: Data) throws(ADBWireError) -> ADBBanner
}
public protocol ADBLink: Sendable {
  func send(_ message: ADBMessage) async throws(ADBError)
  func receive(limits: ADBLimits) async throws(ADBError) -> ADBMessage
  func close() async
}
// ADBNativeTestSupport
public final class MemoryLink: ADBLink { public static func pair() -> (host: MemoryLink, device: MemoryLink)
  public func sever() }   // both ends then fail with .connectionClosed
```
- `message(_:payload:limits:)` rejects (per spec §3 "Limits on receipt"): `magic != command ^ 0xFFFFFFFF` → `.badMagic`; `dataLength > limits.maxData` → `.oversize` (checked in `decodeHeader`, before any payload is read); an unknown command word (including `SYNC 0x434e5953`) → `.unknownCommand`; a checksum mismatch when `verifiesChecksum` → `.badChecksum`; `OPEN`/`WRTE` with `arg0 == 0`, `OKAY` with `arg0 == 0 || arg1 == 0` → `.zeroStreamID`; an `OKAY` payload of a length other than 0 or 4 → `.badOkayPayload`; `AUTH` with `arg0 == 1` and payload ≠ 20 bytes → `.badTokenLength`.
- `ADBBanner.parse` accepts `<systemtype>:<serial>:<k=v;…>`, strips one trailing NUL, and rejects non-UTF-8 or > 4096 bytes with `.badBanner`. `features=` splits on `,`. Model is `ro.product.model`, product `ro.product.name`. The host banner has no trailing NUL unless Task 0 recorded that 8.1 needs one.
- An `ADBLink` maps any `ADBWireError` from the codec to `ADBError.protocolViolation(String(describing:))` and closes itself.

- [ ] Tests:
  - `openHeaderGolden`: `encodeHeader(ADBMessage(command: .open, arg0: 1, arg1: 0, payload: Data("sync:\0".utf8)))` has bytes 0..<4 == `Data("OPEN".utf8)`, `dataLength == 6`, `dataCheck == 503`, `magic == 0xB1BAAFB0`; `decodeHeader` round-trips it.
  - `everyCommandRoundTrips`: for all seven words, decode(encode(m)) == header of m.
  - `checksumWraps`: `checksum(Data(repeating: 0xFF, count: 16_843_010)) == 254`. A valid frame cannot wrap: `255 × 1 MiB < 2³²`, so the function is tested directly.
  - `rejects…` (one test per case above), each asserting the exact `ADBWireError`, and that `decodeHeader` throws `.oversize(1_048_577)` for a 1 MiB + 1 length under `.beforeConnect` without reading a payload.
  - `checksumIgnoredAtSkipVersion`: a wrong `dataCheck` with `verifiesChecksum: false` decodes.
  - `deviceBanner81Parses`: `"device::ro.product.name=p;ro.product.model=m;ro.product.device=d;features=shell_v2,cmd,stat_v2\0"` gives `systemType == "device"`, `features == ["shell_v2","cmd","stat_v2"]`, `properties["ro.product.model"] == "m"`.
  - `hostBannerGolden`: `ADBBanner.host(features: ["shell_v2","cmd","stat_v2","ls_v2"]) == Data("host::features=shell_v2,cmd,stat_v2,ls_v2".utf8)`.
  - `bannerOver4096OrNotUTF8Rejected`.
  - `ADBWireFuzzTests.mutatedFramesNeverCrash`: a fixed seed (`SystemRandomNumberGenerator` is not seedable: implement a SplitMix64 `RandomNumberGenerator` in the test). 10 000 mutations of the golden frames plus 10 000 random 24-byte headers. Each call returns or throws deterministically: the same seed twice gives the same outcomes. No allocation over `limits.maxData`: payload reads are sized by validated `dataLength` only. `FERRY_FUZZ_ITERATIONS` raises the count locally.
- [ ] Commit `feat(adb-native): wire codec, banner and link protocol`.

### Task 5: Keys and AUTH crypto

**Files:** Create `Sources/ADBNative/ADBKeys.swift`, `AndroidPublicKey.swift`, `ADBKeyFile.swift`; `Sources/ADBNativeTestSupport/EphemeralKey.swift`; `Tests/ADBNativeTests/AndroidPublicKeyTests.swift`, `ADBKeyFileTests.swift`, `ADBSigningTests.swift`, `Tests/ADBNativeTests/Fixtures/` (a test-only RSA-2048 key generated for Ferry's tests, PEM in PKCS#1 and PKCS#8 forms, and the expected vectors).

**Interfaces — Produces:**
```swift
public protocol ADBSigningKey: Sendable {
  /// PKCS#1 v1.5 over the SHA-1 DigestInfo of `token` used as the digest. `token` must be 20 bytes.
  func sign(token: Data) throws(ADBError) -> Data
  /// base64(Android key struct) + " " + comment + NUL.
  func publicKeyPayload() throws(ADBError) -> Data
}
public struct SecKeySigningKey: ADBSigningKey { public init(privateKey: SecKey, comment: String) }
public struct ADBKeyring: Sendable {
  public let primary: any ADBSigningKey
  /// Read for each AUTH exchange, dropped after it; nil when absent or unusable.
  public let secondary: @Sendable () -> (any ADBSigningKey)?
}
public enum AndroidPublicKey {
  /// 524 bytes: modulus_size_words (64), n0inv, 256-byte LE modulus, 256-byte LE rr, exponent.
  public static func encode(modulus: Data, exponent: UInt32) throws(ADBError) -> Data
}
public enum ADBKeyFile {
  public static let defaultURL: URL      // ~/.android/adbkey
  public static func load(_ url: URL = defaultURL, comment: String) -> SecKeySigningKey?
}
```
- `sign` uses `SecKeyCreateSignature(_, .rsaSignatureDigestPKCS1v15SHA1, token)`. A token of any other length is `ADBError.protocolViolation`, and nothing is signed.
- `n0inv = -(n⁻¹) mod 2³²` from the lowest modulus word (Newton iteration on `UInt32`). `rr = 2⁴⁰⁹⁶ mod n`: start from 1, double 4096 times with a conditional subtract of `n`, on 64 little-endian `UInt32` limbs (plus a carry limb). Computed once per key and cached by the caller.
- `ADBKeyFile.load` opens the file `O_RDONLY | O_NOFOLLOW`. It accepts `-----BEGIN PRIVATE KEY-----` (PKCS#8; strip the `PrivateKeyInfo` wrapper to the RSA key) and `-----BEGIN RSA PRIVATE KEY-----` (PKCS#1). It returns nil for a missing or unreadable file, other PEM types, encrypted PEM, or a modulus that is not 2048 bits. It never creates `~/.android`, and it logs only at `.debug`.
- Comment: `ferry@<local hostname>` (`ProcessInfo.processInfo.hostName` up to its first `.`).

- [ ] Golden vectors (no hex typed into the plan): generate the test key once with `openssl genrsa -traditional 2048` / `openssl pkcs8 -topk8 -nocrypt`. Compute the expected Android struct with a stdlib-only Python 3 one-off (int arithmetic: `n0inv = (-pow(n, -1, 2**32)) % 2**32`, `rr = pow(2, 4096, n)`, little-endian packing). Compute the expected signature for token `bytes(range(20))` with `openssl pkeyutl -sign -pkeyopt rsa_padding_mode:pkcs1 -pkeyopt digest:sha1 -inkey key.pem -in token.bin` (the tool prefixes the SHA-1 DigestInfo to the 20 input bytes). Commit the outputs as fixture files, and put both commands in the test file's header comment.
- [ ] Tests:
  - `androidStructMatchesIndependentVector`.
  - `publicKeyPayloadEndsWithCommentAndNUL`: last byte 0, then `" ferry@"` before it.
  - `signatureMatchesOpenSSLReference`.
  - `signRefusesNon20ByteTokens` (19 and 21 bytes).
  - `pkcs1AndPkcs8LoadTheSameKey` (same `publicKeyPayload`).
  - `adbkeyLoadReturnsNilFor…`: missing, mode 000 (skipped when running as root), `BEGIN EC PRIVATE KEY`, 1024-bit, encrypted, symlink. (Review Focus 5.)
  - `adbkeyLoadNeverWrites`: run against a temp directory, then assert the directory listing and every file's mtime are unchanged and no `.android` was created under a temp `HOME`.
- [ ] Commit `feat(adb-native): RSA key encoding and AUTH signing`.

### Task 6: `ADBConnection` handshake and auth

**Files:** Create `Sources/ADBNative/ADBConnection.swift`, `ADBConnection+Auth.swift`; `Sources/ADBNativeTestSupport/FakeDeviceWire.swift`; `Tests/ADBNativeTests/ADBConnectionHandshakeTests.swift`.

**Interfaces — Produces:**
```swift
public enum ADBConnectionState: Sendable, Equatable {
  case connecting, unauthorized, online(ADBPeer), tlsRequested, closed(ADBError) }
public struct ADBPeer: Sendable, Equatable {
  public let banner: ADBBanner; public let version: UInt32; public let maxData: UInt32
  public let features: Set<String> }            // host list ∩ banner features
public actor ADBConnection {
  public static let hostFeatures = ["shell_v2", "cmd", "stat_v2", "ls_v2"]
  public static let streamLimit = 64
  public nonisolated let id: UInt64
  public nonisolated let states: AsyncStream<ADBConnectionState>   // newest-wins buffer
  public init(link: any ADBLink, id: UInt64, keyring: ADBKeyring)
  public func start()                       // sends CNXN, starts the single reader task
  public func online() async throws(ADBError) -> ADBPeer   // no timeout of its own
  public func close() async
}
// ADBNativeTestSupport
public actor FakeDeviceWire {
  public enum Profile: Sendable { case android81, current }   // 0x01000000/256 KiB/checksums; 0x01000001/1 MiB
  public enum AuthBehaviour: Sendable { case acceptsKey(Data), promptsThenAllows, denies, none }
  public init(link: MemoryLink, profile: Profile, auth: AuthBehaviour, banner: String,
              services: @escaping @Sendable (String, DeviceStream) async -> Void)
  public func run() async
  public func allow()                       // the user taps Allow
  public func inject(_ message: ADBMessage) async   // raw frame, for hostile-device tests
  public var received: [ADBMessage] { get }
}
```
- Sequence (spec §3–4):
  1. Send `CNXN(0x01000001, 1 MiB, host banner)`.
  2. On `AUTH(TOKEN)`: sign with `primary`, then on the next `TOKEN` with `secondary()` if non-nil, then send `AUTH(RSAPUBLICKEY, primary.publicKeyPayload())` and enter `.unauthorized`. Wait for `CNXN` with no timeout. Each later `TOKEN` gets no answer (the prompt is up).
  3. On the device's `CNXN`: effective version = `min(0x01000001, arg0)`, maxData = `min(1 MiB, arg1)`, limits switch, `.online(peer)`.
  4. `STLS` before `CNXN` enters `.tlsRequested` (P4 handles it; until then the connection closes with `.protocolViolation("TLS required")`).
- Before `CNXN`, frames other than `AUTH`/`STLS`/`CNXN` are ignored, and the `CNXN` and `AUTH` Ferry sends are ≤ 4096 bytes (assert in `send`).
- The secondary key object is released as soon as the AUTH exchange ends (online or public key sent).

- [ ] Tests:
  - `android81NegotiatesChecksummedVersionAnd256KiB`: `peer.version == 0x01000000`, `peer.maxData == 262_144`, and a frame with a bad checksum then closes the connection with `.protocolViolation` (Review Focus 3).
  - `currentNegotiates1MiBAndIgnoresChecksum`.
  - `featuresAreIntersection`: banner `cmd,shell_v2,stat_v2,abb` → `["cmd","shell_v2","stat_v2"]`.
  - `ferryKeyFirstThenAdbkeyThenPublicKey`: with `.promptsThenAllows`, the fake receives `SIGNATURE` (primary), `SIGNATURE` (secondary), then `RSAPUBLICKEY` whose payload equals `primary.publicKeyPayload()`; the state goes `.unauthorized`; after `allow()`, `.online`.
  - `acceptedSecondaryKeyNeedsNoPrompt`: `.acceptsKey(secondary public key)` → online with no `RSAPUBLICKEY` sent.
  - `noSecondaryKeySkipsStraightToPublicKey`.
  - `deniedStaysUnauthorized`: `.denies`, then advance a `ManualClock` by 1 h: still `.unauthorized` and the link is open.
  - `shortTokenClosesConnection` (19 bytes).
  - `framesBeforeCNXNAreIgnored` (a `WRTE` before `CNXN`, then `CNXN` → online).
  - `stlsBeforeCNXNIsReported`.
  - `secondaryKeyIsReadOncePerExchange`: the `secondary` closure's call count is 1 for one handshake.
- [ ] Commit `feat(adb-native): connection handshake and authorisation`.

### Task 7: `NativeStream` and multiplexing

**Files:** Create `Sources/ADBNative/NativeStream.swift`; modify `ADBConnection.swift` (stream table, `open`); extend `FakeDeviceWire` (`DeviceStream`); `Tests/ADBNativeTests/NativeStreamTests.swift`.

**Interfaces — Produces:**
```swift
public actor NativeStream: ADBByteStream { public nonisolated let localID: UInt32 }
extension ADBConnection {
  public func open(_ service: String) async throws(ADBError) -> NativeStream
}
// FakeDeviceWire.DeviceStream: read/write over the device side, with `holdOkay()` / `releaseOkay()`
```
- `open` sends `OPEN(local, 0, service + "\0")`. Local IDs start at 1, increase, and are never reused. The device's `OKAY(remote, local)` completes it, and `CLSE(0, local)` fails it with `.failed("<service> refused")`. A 65th concurrent stream throws `.failed("too many streams")` without sending.
- Send side: `write` splits into payloads ≤ effective maxData, with one `WRTE` outstanding until the peer's `OKAY` (a continuation per stream).
- Receive side: a one-slot buffer. The `OKAY` for a device `WRTE` is sent only once the consumer has taken that payload (`read`/`readSome`). A second device `WRTE` on a stream whose slot is full (no `OKAY` sent) closes the **connection** with `.protocolViolation` (protocol.md "WRITE").
- `CLSE` from the device: pending and later reads get `nil`/`.connectionClosed` after buffered data drains. `cancel()` (nonisolated) sends `CLSE(local, remote)` through the connection, fails the pending read/write with `.cancelled`, and drops later frames for that ID.
- Ignored: an `OKAY` whose sender ID differs from the first, and a `WRTE`/`CLSE` for an unknown or closed ID. A device-initiated `OPEN` gets `CLSE(0, its-id)` (no `reverse`).
- A link failure fails every stream with `.connectionClosed` and ends the connection; its ID is never reused.

- [ ] Tests:
  - `openSendsTrailingNULAndZeroArg1`: the fake receives `OPEN(1, 0, "sync:\0")`.
  - `localIDsIncreaseAndAreNotReused` (open, close, open → IDs 1, 2).
  - `writeWaitsForOkay`: the fake withholds `OKAY`. The second `write` does not complete; after `releaseOkay()` it does. The fake never saw two `WRTE`s outstanding.
  - `writeSplitsAtMaxData`: 600 KiB on `.android81` → `WRTE`s of 262 144, 262 144, 90 112.
  - `okayFollowsConsumption`: the fake sends one `WRTE`, and no `OKAY` arrives until `read`.
  - `secondWrteBeforeOkayClosesConnection` (Review Focus 3).
  - `deviceOpenIsRefused`: the fake injects `OPEN(5, 0, "tcp:80\0")` and receives `CLSE(0, 5)` (Review Focus 3).
  - `sixtyFifthStreamRefused`.
  - `wedgedStreamDoesNotStallItsNeighbour` (Review Focus 2): stream A's device handler never reads and stream B transfers 8 MiB; B completes, A's `cancel()` makes its pending `write` throw `.cancelled`, the fake receives `CLSE(1, ·)`, and B and the link stay open.
  - `unknownIDFramesIgnored`.
  - `severFailsEveryStream`: `MemoryLink.sever()` makes both open streams throw `.connectionClosed`.
- [ ] Commit `feat(adb-native): streams with per-stream backpressure`.

### Task 8: `NativeConnector`, `FakeADBDevice`, both connectors under the same tests

**Files:** Create `Sources/ADBNative/NativeConnector.swift`; `Tests/ADBTransportTests/FakeADBDevice.swift`, `ConnectorBackend.swift`. Modify `FakeAndroid+Server.swift` (make `serve(_ service:_ peer:)` internal so the device front end can call it), `ADBSessionFixture.swift`, `ADBTransportFixture.swift`. `Package.swift`: `ADBTransportTests` gains `ADBNative`, `ADBNativeTestSupport`.

**Interfaces — Produces:**
```swift
public actor NativeConnector: ADBConnector {
  public init(keyring: ADBKeyring)
  /// Starts the handshake on `link` and lists it at once (state `.offline` until CNXN or AUTH
  /// says otherwise). `serial`: the USB serial string, or "host:port" for TCP.
  @discardableResult
  public func attach(_ link: any ADBLink, serial: String, isWireless: Bool) async -> UInt64
  public func detach(connection: UInt64) async
  public func connection(_ id: UInt64) -> ADBConnection?
}
// Tests
enum ConnectorBackend: CaseIterable, Sendable { case server, native }
extension FakeAndroid {
  /// A connector serving this device, and its route; `stop` ends it.
  func connector(_ backend: ConnectorBackend, serial: String)
    async throws -> (connector: any ADBConnector, route: ADBRoute, stop: @Sendable () async -> Void)
}
```
- Connection IDs come from one actor-held counter starting at 1, incremented for every `attach`. `devices()` lists every attached connection as an `ADBDevice` with `via: .native(connection: id)`, state from `ADBConnectionState` (`.unauthorized` → `.unauthorized`, `.online` → `.device`, others → `.offline`), and model/product from the banner. `features(route)` is the peer's intersection set. `open(route:service:)` throws `.deviceGone(serial)` for a `.server` route, an unknown or ended connection, or a serial mismatch.
- `deviceEvents()` yields a list on every attach, detach and state change; it never yields `.unavailable`. Forwards throw `.failed("not supported")` until Task 14.
- `FakeADBDevice` = `FakeDeviceWire(profile: .android81, auth: .acceptsKey(EphemeralKey.shared))` whose `services` closure hands each `OPEN` to `FakeAndroid.serve(service, Peer(stream: DeviceStream))`.
- `ADBFixture.withSession(_ device:, backend: ConnectorBackend = .server, _ body:)`. Parameterise with `@Test(arguments: ConnectorBackend.allCases)` every test that goes through `ADBFixture.withSession` or `FakeAndroid.serve`: the `ADBSession*Tests`, `ADBSync*Tests`, `ADBShellTests`, `ADBLegacyShellTests`, `ADBLogcatTests`, `ADBWatchTests`, `ADBWakeTests`, `ADBDeviceToolsTests`, `ADBDeviceInfoTests`, `ADBStoragesTests`, `ADBLimitsTests`, `ADBMinorFixTests`, `SafeWriterOverADBSessionTests`.
- These stay server-only, because they test `ServerConnector`'s host protocol: `ADBHostTests`, `ADBHostRunTests`, `ADBTrackDevicesTests`, `ADBForwardTests`, `ADBStartServerTests`, `ADBStartFailureTests`, `ADBLocatorTests`, `ADBSocketReleaseTests`, `ADBStreamOpenTests`, `ADBTransport*Tests`, `ADBWireless*Tests`, `ADBWireGoldenTests`.

- [ ] Tests: the parameterised suites pass on `.native`. New:
  - `nativeDeviceListedWithConnectionVia`.
  - `endedConnectionRouteIsGone`: detach, then `open` → `.deviceGone`.
  - `reattachGetsNewIDAndOldRouteStaysGone` (Review Focus 4).
  - `unauthorizedListedAsUnauthorized`.
  - `unplugMidReceive`: sever during a 4 MiB `RECV` → `download` throws `.deviceDisconnected` and no partial file remains.
- [ ] **P1 exit (spec §11):** "Every existing ADB test passes over the native connector on the fake." Ruling: this means every test above the seam, per the list above. Host-protocol tests exercise `ServerConnector` only and have no native counterpart.
- [ ] Commit `feat(adb-native): native connector under the existing session tests`.

### Task 9: `USBLink` over IOUSBHost

**Files:** Create `Sources/ADBNative/USBLink.swift`, `USBFraming.swift`; `Tests/ADBNativeTests/USBFramingTests.swift`, `NativeUSBDeviceTests.swift` (`@Suite(.enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_TESTS"] == "1"), .serialized)`).

**Interfaces — Produces:**
```swift
public enum USBFraming {
  public static func needsZeroLengthPacket(payloadCount: Int, maxPacketSize: Int) -> Bool
}
public enum USBOpenError: Error, Equatable { case exclusiveAccess, noDevice, unusable(String) }
public actor USBLink: ADBLink {
  /// Opens the interface without capture or seize, clears stalls on both bulk pipes.
  public static func open(registryID: UInt64, interfaceNumber: UInt8) async throws(USBOpenError) -> USBLink
  public nonisolated let maxPacketSize: Int   // OUT endpoint descriptor wMaxPacketSize
}
```
- The device suite's keyring is `ADBKeyring(primary: ADBKeyFile.load()!, secondary: { nil })`, the owner's existing `~/.android/adbkey`, read-only, which the units already allow, so no prompt blocks `online()`. The suite is enabled only when that file loads (`.enabled(if:)` on both conditions), and every device call is bounded with `ADBTransport.within(.seconds(10))`.
- `IOUSBHostInterface` is opened with options `[]` (never `.deviceCapture`/`.deviceSeize`). Find the `IOUSBHostInterface` service under the device entry by `bInterfaceNumber`. `kIOReturnExclusiveAccess` → `.exclusiveAccess`. Exactly one bulk IN and one bulk OUT endpoint, else `.unusable`. Call `clearStall()` on both pipes after opening. Max packet size comes from the OUT endpoint descriptor's `wMaxPacketSize` (11 bits), not the pipe's burst figure.
- `send`: the header as one OUT transfer, the payload (if any) as a second, then a ZLP (`nil` data) when `needsZeroLengthPacket`. `receive`: read 24 bytes, decode, then read exactly `dataLength`. A pipe error of "no device" or "aborted" → `.connectionClosed`, and the link closes at once.
- Bulk I/O uses the completion-handler `enqueueIORequest(with:completionTimeout:completionHandler:)` bridged with `withCheckedThrowingContinuation`. Use completion timeout 0 (none) for reads. Cancellation calls `abortWithOption` on the pipe.

- [ ] Tests:
  - `zlpTable` (spec §9): `(511,512)→false`, `(512,512)→true`, `(1024,512)→true`, `(511,1024)→false`, `(512,1024)→false`, `(1024,1024)→true`, `(0,512)→false`.
  - Device suite (owner's unit, adb server stopped): `realDeviceGoesOnline` (`attach(USBLink)` reaches `.online`, and the banner has `features` containing `shell_v2`); `realDeviceStatsInternalStorage` (`ADBSync.stat("/storage/emulated/0")` is a directory); `realDeviceShellEcho` (`run(route:command: "echo 192.0.2.1")` stdout == `"192.0.2.1\n"`, status 0); `realDeviceSecondOpenWhileHeldIsExclusive` (a second `USBLink.open` on the same interface throws `.exclusiveAccess`).
- [ ] Commit `feat(adb-native): USB link over IOUSBHost`.

### Task 10: P1 gate — live check on the three units

- [ ] On the LinkRunner 10G, LinkRunner 100G and EtherScope nXG (Android 8.1), adb server stopped, agent quit: `FERRY_DEVICE_TESTS=1 timeout 600 swift test --filter NativeUSBDeviceTests`. Record pass/fail per unit and `maxPacketSize` per unit.
- [ ] Regression smoke through the refactored server path (Tasks 1–2), with the server running and the current agent from `make app`: browse, copy a 100 MB file both ways with SHA match, screenshot, logcat, port forward, on one unit.
- [ ] Exit (spec §11 P1): "Every existing ADB test passes over the native connector on the fake." There is no kill criterion at P1. If a unit fails the device suite, stop and report: it reopens Task 0's IOUSBHost/libusb decision.
- [ ] Shippable state: Ferry behaves exactly as before. The engine exists but nothing in the agent uses it. Record results in `docs/TESTING.md` (placeholders only); commit `docs: record native ADB P1 device check`.

---

## P2 — Native USB in the agent (6 d)

### Task 11: Ferry's key in the Keychain; fingerprint in the menu

**Files:** Create `Sources/ADBNative/KeychainADBKey.swift`, `ADBKeyFingerprint.swift`. Modify `Apps/FerryAgent/main.swift`; `FerryIPC/Messages.swift` (`StatusReport.adbKeyFingerprint: String?`); `FerryAgentCore/AgentService.swift` (status); `FerryUI/DevicePresentation.swift`, `MenuContent.swift` (unauthorised device expansion), `Localizable.xcstrings`, `help.json`; `docs/user-guide.md`. Tests: `Tests/ADBNativeTests/KeychainADBKeyTests.swift`, `ADBKeyFingerprintTests.swift`, `Tests/FerryUITests` presentation table, `Tests/FerryIPCTests/MessagesTests.swift`.

**Interfaces — Produces:**
- `public enum KeychainADBKey { public static func loadOrCreate(service: String = "io.github.krisarmstrong.ferry.adbkey") throws(ADBError) -> SecKeySigningKey }`. RSA-2048, exponent 65537, non-extractable, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable. The storage is the one Task 0 chose: data-protection keychain with `kSecAttrAccessGroup` = the app group, or the file-based login keychain with a `SecAccess` trusting only the agent. Implement only the one chosen. Lookup is by `kSecAttrApplicationTag`.
- The Android public-key blob (not secret) is cached in Application Support beside `wireless.json` as `adbkey.pub`, rewritten if it does not match the key.
- `public enum ADBKeyFingerprint { public static func display(publicKeyBlob: Data) -> String }`: the hash Task 0 recorded, as uppercase hex pairs joined by `:`.
- `main.swift` builds `ADBKeyring(primary: KeychainADBKey.loadOrCreate(), secondary: { ADBKeyFile.load(comment: …) })`. A Keychain failure logs `.fault`; the engine is then not started, and the server path stays (status unchanged).
- Menu: an expanded device in "Allow USB debugging on the device" state shows a secondary line "Key fingerprint: <value>" (catalog key), selectable to copy.

- The Keychain queries are built by a pure `KeychainADBKey.attributes(service:) -> [String: Any]`, so CI can assert them. An unsigned `swift test` runner has no app-group entitlement (expect `-34018` on the data-protection path), so the real Keychain is exercised only by a suite enabled with `FERRY_KEYCHAIN_TESTS=1` from a signed context, and by Task 17 on the signed agent.
- [ ] Tests:
  - `attributesAreNonExtractableThisDeviceOnly` (CI: `kSecAttrIsExtractable == false`, the accessibility class, `kSecAttrSynchronizable == false`, `kSecAttrKeySizeInBits == 2048`, and the access group or ACL Task 0 chose).
  - Gated: `createsOnceThenLoadsTheSameKey` (two calls → identical `publicKeyPayload`; test-only `service`, deleted in `defer`) and `privateKeyIsNotExtractable` (`SecKeyCopyExternalRepresentation` fails).
  - `fingerprintFormat` (an expected value computed with `python3 -c` or `openssl dgst` over the fixture blob; command in the test comment).
  - Presentation: fingerprint shown only for `awaitingUSBDebugging` devices.
  - `MessagesTests` round-trips `adbKeyFingerprint`.
- [ ] Commit `feat(adb-native): Ferry's ADB key in the Keychain with its fingerprint`.

### Task 12: Native USB device table in the agent

**Files:** Create `Sources/ADBNative/NativeUSB.swift`, `USBClaimPolicy.swift`, `Sources/ADBTransport/ADBUSBControl.swift`; modify `NativeConnector.swift` (no-device failure detaches at once), `ADBTransport.swift` (`usb:` init parameter, scan reads `usbStatus()`); `MTPTransport/USBCandidates.swift` (doc only: `0x18D1_4EE7` stays `.notSharing` for MTP, and ADB serves it); `Apps/FerryAgent/main.swift`. Tests: `Tests/ADBNativeTests/USBClaimPolicyTests.swift`, `NativeUSBTests.swift`; `Tests/FerryAgentCoreTests/CompositeTransportTests.swift`.

**Interfaces — Produces:**
```swift
public struct USBClaimPolicy: Sendable {
  public static let serverGrace = Duration.seconds(5)
  public enum Decision: Equatable, Sendable { case claim, waitUntil(ContinuousClock.Instant), leaveToServer, yielded }
  public static func decide(serial: String?, appearedAt: ContinuousClock.Instant,
    now: ContinuousClock.Instant, serverRunning: Bool, serverUSBSerials: Set<String>,
    yielded: Bool) -> Decision
}
public protocol USBInterfaceSource: Sendable {   // the registry, or a test's list
  func adbInterfaces() -> [(registryID: UInt64, interfaceNumber: UInt8, serial: String?)]
  func open(registryID: UInt64, interfaceNumber: UInt8) async throws(USBOpenError) -> any ADBLink
}
// ADBTransport (so ADBTransport never imports ADBNative); NativeUSB conforms.
public struct ADBUSBStatus: Sendable, Equatable {
  public var serverRunning: Bool
  /// USB serials whose ADB interface another program holds and the server does not list.
  public var inUseElsewhere: Set<String>
}
public protocol ADBUSBControl: Sendable {
  func usbStatus() async -> ADBUSBStatus
  /// Detaches and reclaims the interface of a natively held USB device (Check Again).
  func reconnect(serial: String) async
  /// Releases the interface for the user's adb server (Task 15). False if not held natively.
  func yield(serial: String) async -> Bool
}
public actor NativeUSB: ADBUSBControl {
  public init(connector: NativeConnector, source: any USBInterfaceSource,
              serverEvents: AsyncStream<ADBDeviceEvent>, ticks: AsyncStream<Void>,
              clock: any Clock<Duration>, now: @escaping @Sendable () -> ContinuousClock.Instant)
  public func run() async
}
```
- Policy (spec §6): yielded → `.yielded`; the server lists the serial → `.leaveToServer`; the server is running and doesn't list it, before `appearedAt + 5 s` → `.waitUntil`; otherwise `.claim`. A claim that fails with `.exclusiveAccess` is rechecked on the next scan; it shows as "in use by another program" only if the server does not list it then. `ADBTransport.init(connector:usb: (any ADBUSBControl)? = nil, …)`: each scan reads `usbStatus()` and reports `inUseElsewhere` serials in `DeviceScan.busy` as `DeviceInfo(id: DeviceID(serial:), manufacturer: "", model: "Android device")`.
- `NativeUSB` rescans on each tick, on each server event (a server exit releases interfaces with no IOKit event), and at each `waitUntil` deadline (injected clock). Claimed registry IDs map to connection IDs. A registry ID that disappears detaches its connection.
- Check Again (spec §4 user flow): `ADBTransport.unpark(_:)` for a natively unauthorised USB device calls `usb.reconnect(serial:)`, which detaches and reclaims its interface. It is the only way back from Deny besides a replug.
- `main.swift`: a second `USBWatcher.ticks(state:)` subscription feeds `NativeUSB` (the hub keeps its own); `serverEvents` comes from `ServerConnector.deviceEvents()`.

- [ ] Tests:
  - Policy table: no server → `.claim`; server lists the serial → `.leaveToServer`; server running and not listing at +1 s → `.waitUntil(appeared + 5 s)`; at +5 s → `.claim`; yielded with the server listing it → `.yielded`.
  - `NativeUSBTests` (fake source returning `MemoryLink`s, `ManualClock`): `claimsWhenNoServer`; `checkAgainReconnectsUnauthorized` (a second open with a new connection ID); `waitsFiveSecondsThenClaims` (advance 4.9 s: no open; 0.1 s more: one open); `serverExitTriggersClaimWithoutUSBTick`; `unpluggedInterfaceDetaches` (old route `.deviceGone`, Review Focus 4); `exclusiveAccessReportedBusyOnlyIfServerDoesNotList`.
  - `CompositeTransportTests.chargeOnlyWithDebuggingServedOverADB`: MTP `.notSharing` + native ADB `.device` for `0123456789abcdef` → one device, method `.usbADB`.
- [ ] Commit `feat(agent): claim ADB interfaces natively, deferring to a running server`.

### Task 13: `RoutingConnector`; Ferry stops starting the server

**Files:** Create `Sources/ADBTransport/RoutingConnector.swift`. Modify `ServerConnector.swift` (tracking never calls `startServer`; `startServer`, `launcher` and `Backoff`-driven start removed), `ADBTransport.swift` (no `startADBServer`, status), `DeviceKit/DeviceTransport.swift` (remove `startADBServer`), `DeviceKit/ADBStatus.swift` (remove `.serverDown`), `CompositeTransport.swift`, `DeviceHub+Requests.swift` (remove `recheckADB`), `DeviceKitTestSupport/FakeTransport.swift`, `Apps/FerryAgent/main.swift`. IPC: remove `AgentRequest.recheckADB` from `Messages.swift`, `FerryIdentity.swift`, `RequestCancellation.swift`, `AgentService.swift`, `AgentService+Validation.swift`. UI: delete `ADBNotRunningRow`; `AppModel+ADB.swift` (`recheckADB`, `showsADBNotRunning`), `MenuContent.swift`, `AppModel.swift:315`, `InstallADBRow.swift` (Check Again re-requests `.status`), help/catalog/user guide. Tests: `FerryIPCTests/MessagesTests.swift`, `AgentClientTests.swift`, `FerryProviderCoreTests/FakeAgent.swift`, `AgentADBStatusTests.swift`, `ADBStartServerTests.swift` and `ADBStartFailureTests.swift` (deleted), new `Tests/ADBTransportTests/RoutingConnectorTests.swift`, `Tests/ADBTransportTests/ADBTransportHandoverTests.swift`, `Tests/FerryAgentCoreTests/DeviceHubRouteChangeTests.swift`, `ADBWirelessTests.swift`.

**Interfaces — Produces:**
- `public actor RoutingConnector: ADBConnector { public init(server: any ADBConnector, native: any ADBConnector) }`.
  - `devices()` = native list ∪ server list, one entry per serial.
  - When both sides list a serial, the side chosen earlier for it is kept while that side still lists it; a new serial goes native. This is the "route already held is kept" rule.
  - A server failure (`.serverUnavailable`) contributes an empty server list; it is not an error.
  - Every call dispatches on `route.via`.
  - `deviceEvents()` merges both; it never yields `.unavailable`.
- `ADBStatus` becomes `{ available, notInstalled }`. `.notInstalled` now means only "the `adb` command Pair with Code and Connect by Address still use is missing" (until Task 19). `InstallADBRow` shows only when `wantsNetwork`.
- `main.swift`: `ServerConnector()`, `NativeConnector(keyring:)`, `RoutingConnector(server:native:)`, `ADBTransport(connector: routing, usb: nativeUSB, …)`, `ADBTools` over the same.
- **Keeping P2 shippable for Wi-Fi:** `ADBWireless.init(server: ServerConnector, routing: any ADBConnector, run: ADBCommandRunner)`. `connect`, `disconnect` and `pair` drop `requireServer()` (the `adb` command starts its own server, the interim the spec accepts). `devices()`, `device(at:)`, `tcpPort(of:)`, `networkAddresses(of:)`, `restartInTCPMode` and `deviceEvents()` go over `routing`, so Use over Wi-Fi reaches a natively held USB unit. `mdnsServices()` stays on `server`.

- [ ] Tests:
  - `RoutingConnectorTests`: `heldSideKeptWhenBothList`; `newSerialGoesNative`; `serverDownIsEmptyNotError`; `serverRouteNeverReachesNative` (server `transport_id` "7" vs native connection 7: an `open` on each reaches only its own fake, Review Focus 4).
  - `ServerConnector` has no launcher after this task, so "never starts the server" is checked at the Task 17 gate (`pgrep -x adb` empty after the run). The start-server tests are deleted with the code.
  - `ADBWirelessTests.useOverWiFiReachesNativeUSB`: `networkAddresses(of:)` with a `.native` route is answered by the native fake.
  - Review Focus 1, in two halves:
    - `Tests/ADBTransportTests/ADBTransportHandoverTests.swift`: a real `ADBTransport` over a `RoutingConnector` with a `FakeADBServer` and a `FakeADBDevice` for the same serial. A download runs on the server route; the fake server stops; the download fails with `.deviceDisconnected` and leaves no partial file; the next scan lists the device with `.native` and `open` succeeds. A server that starts listing the serial while the native session is held changes neither the held route nor the session.
    - `Tests/FerryAgentCoreTests/DeviceHubRouteChangeTests.swift` (`FakeTransport`): a held `.usbADB` session reports `.deviceDisconnected` and the next scan offers the same device by the same method. The domain identifier and the `ItemTable` IDs are unchanged.
  - `MessagesTests`: tags renumbered with no gap.
- [ ] Commit `feat(adb): route devices natively or through a running server; never start the server`.

### Task 14: Native port forwards

**Files:** Create `Sources/ADBNative/NativeForwards.swift`; modify `NativeConnector.swift`. Test: `Tests/ADBNativeTests/NativeForwardTests.swift`.

**Interfaces — Produces:** `NativeConnector.forwards(route:)`, `addForward(route:_:)`, `removeForward(route:local:)` implemented with one `NWListener` per forward. The listener uses `requiredLocalEndpoint = 127.0.0.1:<local>`, `allowLocalEndpointReuse = false`, and `acceptLocalOnly = true`. Each accepted connection opens `tcp:<remote>` on the route's connection and pumps both ways through `NativeStream` (a closed side closes the other).
- `norebind` semantics: a local port Ferry already forwards, or one the OS refuses (in use) → `.failed("cannot bind tcp:<local>")`.
- A connection that ends removes its forwards.

- [ ] Tests:
  - `forwardPumpsBothWays`: a test client connects to 127.0.0.1:<local>, writes "ping"; the fake device service `tcp:80` echoes; the client reads "ping".
  - `listedAfterAdd`.
  - `secondAddOnSamePortRefused`.
  - `removeClosesListener` (a connect is then refused).
  - `connectionEndDropsForwards`.
  - `listenerIsLoopbackOnly` (its endpoint host is `127.0.0.1`).
- [ ] Commit `feat(adb-native): port forwarding on loopback`.

### Task 15: Let adb Use This Device

**Files:** Modify `NativeUSB.swift` (implements `ADBUSBControl.yield`); `ADBTransport.swift` (scan sets `offersADBHandOff` = held devices whose route is `.native` over USB while `usbStatus().serverRunning`; `releaseToADBServer` calls `usb.yield(serial:)`); `DeviceKit/DeviceTransport.swift` (`func releaseToADBServer(_ id: DeviceID) async -> Bool`, default false), `DeviceKit/DeviceScan.swift` (`offersADBHandOff: Set<DeviceID>`), `CompositeTransport.swift`; `DeviceHub+Requests.swift` (`letADBUse(_:)`). IPC: `AgentRequest.letADBUse(DeviceID)` in `Messages.swift`, `FerryIdentity.swift` (app role only), `RequestCancellation.swift`, `AgentService.swift`, `AgentService+Validation.swift`; `StatusReport.offersADBHandOff: [DeviceID]`. UI: menu row "Let adb Use This Device" in the device expansion (last group, above Eject), `DevicePresentation.swift`, catalog, `help.json` (Troubleshooting: "adb says no devices"), user guide. Tests: `MessagesTests`, `AgentClientTests`, `FakeAgent`, `Tests/ADBNativeTests/NativeUSBTests.swift`, `Tests/FerryAgentCoreTests/DeviceHubHandOffTests.swift`, FerryUI presentation.

- [ ] Behaviour (spec §6, O5 controller call):
  1. Offered only for a device held natively over USB while a server is running.
  2. The hub waits for in-flight leases (`requestsFinished`), closes the session, then calls `releaseToADBServer`.
  3. `NativeUSB` detaches and closes the interface, and marks the registry ID yielded.
  4. A yielded ID is never reclaimed while the server runs. The mark clears when the registry ID disappears (replug) or the server exits.
  5. Ferry never yields on its own.
  6. If Task 0 recorded that a running server does not pick up a released interface, the row's help says to unplug and plug the device back in.
- [ ] Tests:
  - `yieldedInterfaceNotReclaimedOnNextTicks` (advance past 5 s, three ticks: no open).
  - `yieldClearsOnReplug` (new registry ID → claimed when no server).
  - `yieldClearsWhenServerExits`.
  - `handOffWaitsForLeases` (a held lease delays the close until released).
  - `offeredOnlyWhileServerRunsAndHeldNatively` (presentation table).
  - `serverStartDoesNotYield`.
- [ ] Commit `feat(agent): Let adb Use This Device`.

### Task 16: Open in Terminal without `adb` (ruling, controller to confirm)

The spec is silent. Today `ShellLaunch` runs the located `adb -s <serial> shell`, which Task 19 deletes, and a user's server cannot see a natively held unit. The smallest ruling that keeps the feature: a one-shot loopback bridge in the agent.

**Files:** Create `Sources/ADBNative/ShellBridge.swift`; modify `FerryIPC/Tools.swift` (`ShellTarget` becomes `{ port: UInt16, token: String }`, validated: port 1024…65535, token 64 lowercase hex), `FerryAgentCore/ADBTools+Developer.swift`, `AgentService+Tools.swift`, `FerryUI/ShellLaunch.swift`, `AppModel+Developer.swift`, help; delete `ADBDeviceTools.adbPath()`. It sits in P2 because a natively held unit is invisible to the user's server, so the old script cannot reach it once Task 13 lands. Tests: `Tests/ADBNativeTests/ShellBridgeTests.swift`, `FerryUITests` ShellLaunch script tests, `FerryIPCTests` ShellTarget validation.

- [ ] Agent: on `.shellTarget(id)`, open a legacy `shell:` stream (PTY on the device) on the session's route. Listen on `127.0.0.1:0`, take exactly one connection within 30 s (injected clock), require the 32-byte random token (hex, newline-terminated) as its first line, else close. Then pump bytes both ways; either side closing ends both. Any other connection is closed.
- [ ] Script: `stty raw -echo; { printf '%s\n' <token>; cat; } | /usr/bin/nc 127.0.0.1 <port>; stty sane`. It removes itself first, as today. One layer of zsh quoting, over validated values.
- [ ] Tests:
  - `wrongTokenClosed`.
  - `secondConnectionRefused`.
  - `unusedBridgeExpiresAfter30s` (ManualClock).
  - `bytesPumpBothWays` (fake device `shell:` echo).
  - `deviceCloseEndsClient`.
  - `scriptHasOneQuotingLayer` (golden script text for port 40000 and a fixed token).
- [ ] Commit `feat(tools): Open in Terminal through the agent`.

### Task 17: P2 gate — live run on the three units

- [ ] Setup: `adb kill-server` once; Ferry from `make app`. For each of LinkRunner 10G, LinkRunner 100G and EtherScope nXG over USB with no server running, run Plan 2b Task 11's USB list:
  - copy a 5 GB file both ways with SHA match;
  - the Review Focus 3 names (`'`, `$`, backslash, leading `-`, newline, emoji);
  - method swaps MTP→ADB→MTP;
  - inotify pickup;
  - APK install, screenshot, 10 s recording, logcat, port forward (Task 14), device info, Open in Terminal (Task 16).
- [ ] Interim Wi-Fi paths still work: Use over Wi-Fi on a natively held LinkRunner on a network, and Connect by Address to the EtherScope on 192.0.2.x (through `adb`, which may start a server).
- [ ] Signed-agent Keychain check: the key exists with the chosen storage (Task 0); `security find-key` (or the data-protection equivalent) shows it is not extractable. It survives an agent restart and a `make app` rebuild (same fingerprint).
- [ ] Never starts the server: with no server running at the start, after the whole USB run (no Wi-Fi forms used), `pgrep -x adb` prints nothing.
- [ ] Allow/Deny on a fresh key: delete the Keychain key, revoke authorisations on the unit, plug in. The menu shows "Allow USB debugging on the device" with the fingerprint, which matches the unit's dialog. Deny → the row stays unauthorised until Check Again or a replug. Allow → served. A unit already allowed for `adb` connects with no prompt (adbkey second key). `ls -la ~/.android` is unchanged before and after (mtimes recorded).
- [ ] With the server running (`adb start-server` before plugging in): Ferry serves through it ("USB · ADB"). `adb kill-server` mid-copy → Review Focus 1 behaviour, then native. Start a server while held natively → no change; Let adb Use This Device → `adb devices` lists it (or the replug help applies per O-B4).
- [ ] **Throughput (kill criterion):** same unit, cable and 5 GB file as Task 0's baseline. Measure the native copy both ways with `time` (MB/s = bytes / seconds), three runs, median. **Kill / rethink (spec §11 P2):** "native 5 GB transfer below 70 % of the server path's throughput on the same unit and cable after one profiling pass." If below 70 %, do one profiling pass (Instruments Time Profiler on the agent), fix within the task's scope, and remeasure. If still below, stop and report to the controller.
- [ ] Exit (spec): "Task 11 list passes on all three units." Shippable state: USB ADB with no `adb` installed. Until P3, Pair with Code and Connect by Address still run `adb` and may start a server, which then claims USB interfaces Ferry does not already hold. This is accepted and noted in help. Record in `docs/TESTING.md`; commit `docs: record native USB ADB live run`.

---

## P3 — Native TCP (4 d)

### Task 18: `TCPLink`, `NativeWireless`, Local Network

**Files:** Create `Sources/ADBNative/TCPLink.swift`, `NativeWireless.swift`. Modify `ServerConnector.swift` (`pair(_:code:)`, `connect(_:)` via host services, below); `FerryAgentCore/WirelessADB*.swift` (failure mapping); `FerryIPC/Wireless.swift` (`WirelessFailure.localNetworkDenied`, `.pairingNeedsADBServer`); `ADBWire.swift` (`ADBError.localNetworkDenied`); `Apps/FerryAgent/Info.plist`, `Apps/Ferry/Info.plist`; `Apps/FerryAgent/main.swift`; FerryUI network forms, catalog, `help.json`, user guide. Tests: `Tests/ADBNativeTests/TCPLinkTests.swift`, `NativeWirelessTests.swift`; `Tests/FerryAgentCoreTests/WirelessADB*Tests.swift` (failure cases).

**Interfaces — Produces:**
- `public actor TCPLink: ADBLink { public static func connect(_ endpoint: WirelessEndpoint, timeout: Duration) async throws(ADBError) -> TCPLink }`. It uses `NWConnection` with TCP and frames the header and payload as one send. A `.waiting` state whose path has `unsatisfiedReason == .localNetworkDenied`, or an `NWError.dns(kDNSServiceErr_PolicyDenied)`, → `.localNetworkDenied`. A refusal → `.failed("refused")`. The timeout comes from the caller (`ADBTransport.defaultAnswerLimit`-style bound, injected).
- `public struct NativeWireless: WirelessADBControl { public init(native: NativeConnector, server: ServerConnector, routing: RoutingConnector) }`:
  - `connect`: TCP + attach; `.online` → `.connected(serial: endpoint.argument)`, `.unauthorized` → `.awaitingAllow`.
  - `disconnect`: detaches a native connection to that address. A server-held address is not disconnected (Ferry never detaches the user's server's devices); Forget only forgets.
  - `device(at:)`, `tcpPort(of:)`, `networkAddresses(of:)`: over `routing`.
  - `restartInTCPMode`: `OPEN tcpip:<port>` and read the reply as today.
  - `deviceEvents`: `routing.deviceEvents()`.
  - `mdnsServices`: `server.query("host:mdns:services")` when a server runs, else `[]` (until Task 26).
  - `pair`: through the user's running server (below), else `.failed(.pairingNeedsADBServer)`.
- **Pair with Code between P3 and P4 (ruling):** `ServerConnector.pair(_:code:)` sends the host service adb's own `adb pair` sends to its server, and `connect` uses the `adb connect` host service. Verify both request strings against `client/commandline.cpp` / `client/adb_wifi.cpp` / `adb.cpp` before coding; the fake server test pins what was found. With no server running, the form says "Pair with Code needs adb running on this Mac for now." with a help link. This is also the end state if P4 is shelved. It never starts a server.
- Info.plists: `NSLocalNetworkUsageDescription` = "Ferry connects to Android devices you add over Wi-Fi or Ethernet." and `NSBonjourServices` = `_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`, in the agent's (English only: a bundle-less tool cannot localise its embedded plist; stated exception) and Ferry.app's (localised through `Apps/Ferry/InfoPlist.xcstrings`). Task 20 records which text the alert shows and removes the unused copy.
- Prompt timing (O3): no LAN connect and no browse at agent launch unless `wireless.json` holds remembered devices. Their reconnect at start is a network feature the user already used.
- Help (spec §8): the Wi-Fi topic says to use plain TCP (Connect by Address, Use over Wi-Fi) only on a trusted network. Add the sentence if Plan 2b Task 19 did not. Update `WirelessADB.failure(_:)`'s exhaustive switch for the new `ADBError` cases.
- Local Network denied → `WirelessOutcome.failed(.localNetworkDenied)` → the form shows "Ferry isn't allowed to reach devices on your network. Turn on Ferry in System Settings > Privacy & Security > Local Network.", with a help topic.

- [ ] Tests:
  - `TCPLinkTests` (loopback `NWListener` running `FakeDeviceWire` over the socket): `connectsAndGoesOnline`; `refusedMapsToFailed`; `policyDeniedMapsToLocalNetworkDenied`, driven through the pure `TCPLink.failure(for state:path:)` (Review Focus 5).
  - `NativeWirelessTests`: `connectUnauthorizedIsAwaitingAllow`; `disconnectLeavesServerHeldAddressAlone`; `tcpipOpensService` (the fake receives `OPEN(·,0,"tcpip:5555\0")`); `pairWithoutServerNeedsServer`; `pairThroughServerSendsHostService`.
  - `WirelessADB`: `localNetworkDeniedOutcome`; `noLaunchConnectWithEmptyStore` (the fake `connect` count is 0 after `run()` starts with an empty store).
- [ ] Commit `feat(adb-native): network devices without adb`.

### Task 19: Remove the `adb` locator and launcher (spec §10)

**Files:** Delete `ADBLocator.swift`, `ADBCommand.swift`, `ADBWireless.swift`, `ADBLocatorTests.swift`, `ADBWireless*Tests.swift` (their behaviours are covered by `NativeWirelessTests`; `networkAddresses(fromIPAddr:)` with its `dummy*` exclusion, `networkInterfacePrefixes` and `detail(_:)` move to `NativeWireless` with their test cases), `InstallADBRow.swift`, `AgentADBStatusTests.swift`. Delete `DeviceKit/ADBStatus.swift` with `DeviceScan.adbStatus`, `StatusReport.adbStatus`, `ADBError.adbNotInstalled`, `ServerConnector`'s locator and `adbURL()`, `WirelessFailure.adbUnavailable`. Modify `MenuContent.swift` (network forms shown whenever `agent == .running`), `AppModel*.swift`, `DevicePresentation.installCommand`, `PreviewClient.swift`, `CompositeTransport.swift`, `FakeTransport.swift`, `WirelessADB+Connecting.swift` (`failure`), `help.json`, catalogs (remove unused keys), `docs/user-guide.md`, `README.md` (drop "Optional … `adb`"), `Apps/FerryAgent/main.swift`. Tests: `MessagesTests` (`ADBStatus` loop removed), FerryUI snapshots regenerated (192.0.2.x).

- [ ] `rg -n 'android-platform-tools|adbNotInstalled|ADBLocator|ADBCommand|notInstalled|Install adb' Sources Apps Tests README.md docs/user-guide.md` returns nothing (the spec and plans are exempt).
- [ ] Tests: `networkFormsShownWithoutADBStatus`; help-coverage table updated (every error string maps to a topic); the catalog has no orphan keys.
- [ ] Commit `refactor(adb): remove the adb locator and launcher`.

### Task 20: P3 gate — EtherScope over the network

- [ ] With no `adb` on the Mac's PATH (rename `/opt/homebrew/bin/adb` for the run, restore after): EtherScope nXG over Connect by Address on 192.0.2.x. The first connect raises the Local Network alert attributed to Ferry; record which Info.plist's text it shows and remove the unused copy in a follow-up commit. Then run Plan 2b Task 11's Wi-Fi rows:
  - copy over the network, 5 GB with SHA;
  - unplug USB mid-session (method changes to Wi-Fi);
  - remembered-address reconnect after an agent restart;
  - Use over Wi-Fi (`tcpip`) from USB on a LinkRunner on a network.
- [ ] Deny Local Network once (System Settings), retry: the form shows the Task 18 message; re-allow, and it works.
- [ ] Open in Terminal on a USB unit and a network unit: an interactive shell, `exit` returns, and `ps` shows no leftover bridge.
- [ ] Exit (spec §11 P3): "EtherScope over 192.0.2.x passes Task 11's Wi-Fi rows." No kill criterion at P3. **P4 gate check:** the owner's Android 11+ phone is available (O4: yes). If it is not by the end of P3, P4 is shelved per the spec, and Task 18's Pair-through-server state is final.
- [ ] Shippable state: everything Ferry does today on the NetAlly units, with no install. Record in `docs/TESTING.md`; commit `docs: record native TCP live run`.

---

## P4 — TLS and pairing (9 d)

### Task 21: P4 entry spike — Network.framework TLS (1 d)

**Files:** `docs/spikes/2026-12-adb-tls.md`; spike code on `spike/adb-tls`, never merged.

- [ ] Against the owner's Android 11+ phone (wireless debugging on) and a loopback TLS 1.3 server, answer O-B7:
  1. An `NWProtocolFramer` that runs the plaintext CNXN/STLS exchange, then `prependApplicationProtocol` with TLS options and passes through, completes a TLS 1.3 handshake on the phone's connect port (Apple Developer Forums thread 129901).
  2. `sec_protocol_metadata_create_secret` (RFC 5705 exporter) accepts the 10-byte label `"adb-label\0"` with no context and returns 64 bytes.
  3. A `SecIdentity` over the non-extractable Keychain RSA key signs the TLS 1.3 CertificateVerify (RSA-PSS SHA-256).
  4. `sec_protocol_options_set_verify_block` accepts any server certificate and exposes its DER.
  5. `sec_protocol_options_set_min/max_tls_protocol_version` both `.TLSv13`.
  6. **O-B1:** do the pairing port and the connect port present the same certificate (SHA-256 of DER)?
- [ ] `Decision:` Network.framework for both, or the BoringSSL `libssl` fallback (memory BIOs over `TCPLink`, `SSL_PRIVATE_KEY_METHOD` signing through `SecKey`), naming the amended tasks (23, 24, 25). Also: pin the pairing-port or the connect-port certificate (O-B1).
- [ ] **Kill (spec §11 P4):** "the STLS framer and the BoringSSL `libssl` fallback both fail to interoperate within 3 days of P4". If the framer fails on day 1, Task 22 vendors libssl as well, and the fallback must interoperate by day 3, else stop and report. Commit `docs: record ADB TLS spike`.

### Task 22: Vendored BoringSSL for SPAKE2 (`CBoringSPAKE`)

**Files:** Create `scripts/vendor-boringssl.sh`, `Sources/CBoringSPAKE/` (generated), `Sources/ADBNative/SPAKE2.swift`, `ThirdPartyNotices/BoringSSL-LICENSE`; modify `Package.swift` (C target `CBoringSPAKE`, `ADBNative` depends on it), `project.yml` (copy `ThirdPartyNotices/` into Ferry.app Resources), `Makefile` (`check-app` asserts `$(APP)/Contents/Resources/ThirdPartyNotices/BoringSSL-LICENSE` exists), `.github/workflows/ci.yml` (no change expected: SwiftPM builds the C target from source). Test: `Tests/ADBNativeTests/SPAKE2Tests.swift`.

- [ ] Mechanics, defined here because nothing exists to mirror (CI installs libmtp from Homebrew):
  - `vendor-boringssl.sh <commit>` clones `https://boringssl.googlesource.com/boringssl` at that commit.
  - It copies `crypto/` (libcrypto, whole, as the spec requires: `spake25519.cc` uses `fipsmodule/bn` and `curve25519.cc` internals) and `include/openssl`, and applies a symbol prefix `FERRY_BSSL_` using BoringSSL's own prefixing support (`BORINGSSL_PREFIX` with the generated `boringssl_prefix_symbols.h`, as swift-crypto's vendoring does).
  - It writes `Sources/CBoringSPAKE/VENDORED_COMMIT` and copies `LICENSE`.
  - Run it once and **record the commit actually vendored** in the commit message. Pick the newest commit at least 14 days old; never a hash written ahead of time.
  - Confirm the current licence text (Apache-2.0 since 2024, with earlier ISC/OpenSSL parts if still present) and ship it as is.
  - `CBoringSPAKE` exposes only `curve25519.h` (SPAKE2) to Swift through its module map. Excluded: anything needing assembly that SwiftPM cannot build (use `OPENSSL_NO_ASM`).
- [ ] `public struct SPAKE2Alice { public init(password: Data, myName: Data = Data("adb pair client\0".utf8), theirName: Data = Data("adb pair server\0".utf8)) throws(ADBError); public func message() -> Data /* 32 bytes */; public consuming func finish(theirMessage: Data) throws(ADBError) -> Data /* key material */ }`, wrapping `SPAKE2_CTX_new(spake2_role_alice, …)`, `SPAKE2_generate_msg`, `SPAKE2_process_msg`. The password-scalar hack is left at BoringSSL's default (not disabled).
- [ ] Tests:
  - `aliceAndBobAgree` (Bob through the same C API in the test; both keys equal).
  - `wrongPasswordDisagrees`.
  - `namesIncludeTheirNUL` (`myName.count == 16`).
  - `fixedRandomnessGolden`: BoringSSL's `RAND_bytes` is replaced in the test build via its `BORINGSSL_UNSAFE_DETERMINISTIC_MODE` define on a test-only copy, or, if that define is unavailable at the vendored commit, the golden is dropped and the device run in Task 27 is the cross-check. Record which in the task report.
- [ ] Commit `build: vendor BoringSSL for SPAKE2`.

### Task 23: TLS client identity

**Files:** Create `Sources/ADBNative/TLS/ADBCertificate.swift`, `TLSIdentity.swift`; Test: `Tests/ADBNativeTests/ADBCertificateTests.swift`.

**Interfaces — Produces:**
- `public enum ADBCertificate { public static func make(key: SecKey, notBefore: Date) throws(ADBError) -> Data /* DER */ }`. Hand-built DER, no new dependency: X.509 v3, subject = issuer = `C=US, O=Android, CN=Adb`, basic constraints (CA true, critical), key usage (keyCertSign, cRLSign, digitalSignature; critical), subject key identifier, validity 10 years, `sha256WithRSAEncryption` signed by `SecKeyCreateSignature(.rsaSignatureMessagePKCS1v15SHA256)` (`crypto/x509_generator.cpp`). Built once; stored beside the key (certificate in the Keychain as `kSecClassCertificate`, so `SecIdentity` resolves).
- `public enum TLSIdentity { public static func identity() throws(ADBError) -> SecIdentity; public static func caListFingerprint(publicKey: SecKey) -> String }`: the uppercase hex SHA-256 of the DER SubjectPublicKeyInfo (`tls/adb_ca_list.cpp`, `client/auth.cpp` `hash_key`).

- [ ] Tests:
  - `certificateParses`: `SecCertificateCreateWithData` succeeds; the subject summary is "Adb".
  - `certificateMatchesOpenSSLView`: `openssl x509 -inform DER -noout -subject -issuer -dates -ext basicConstraints,keyUsage` output is recorded as a fixture from one run, and the test asserts the fields Ferry sets.
  - `caFingerprintIs64UppercaseHex`.
  - `caFingerprintMatchesIndependentHash` (`openssl pkey -pubin -outform DER | shasum -a 256`, command in the test comment).
- [ ] Commit `feat(adb-native): TLS client certificate for ADB`.

### Task 24: `TLSLink` and STLS

**Files:** Create `Sources/ADBNative/TLS/TLSLink.swift` and `STLSFramer.swift` (or `BoringTLS.swift` per Task 21); modify `ADBConnection.swift` (`.tlsRequested` → reply `STLS(0x01000000)`, upgrade, continue CNXN inside TLS, ignore `AUTH`), `NativeConnector.swift` (`attach` accepts an upgradable TCP link), `ADBWire.swift` (`ADBError.notPaired`). Tests: `Tests/ADBNativeTests/TLSLinkTests.swift` (loopback TLS 1.3 server built with `NWListener` + `NWProtocolTLS`, a test identity).

- [ ] Behaviour (spec §5): TLS 1.3 only; Ferry is the client. It presents its certificate whether or not the CA list names it. It reads the CA list only to report `.notPaired` early when `caListFingerprint` is absent. A close right after the handshake → `.notPaired`.
- [ ] Tests:
  - `stlsReplyAndUpgrade` (the fake device sends `STLS`; Ferry replies `STLS(0x01000000)`; after the handshake, CNXN online inside TLS).
  - `authIgnoredAfterTLS`.
  - `closeAfterHandshakeIsNotPaired`.
  - `tls12ServerRefused`.
  - `caListWithoutFerryReportsNotPairedEarly`.
- [ ] Commit `feat(adb-native): TLS connections for Android 11+`.

### Task 25: Pairing client

**Files:** Create `Sources/ADBNative/TLS/PairingCodec.swift`, `PairingClient.swift`; Tests: `Tests/ADBNativeTests/PairingCodecTests.swift`, `PairingClientTests.swift` (a fake pairing server over loopback TLS, running `SPAKE2` as Bob).

**Interfaces — Produces:**
- `PairingCodec`: `header(type: UInt8, length: UInt32) -> Data` (version 1, type, big-endian u32), `parseHeader(_:) throws(ADBError)` (version must be 1, type 0 or 1, length ≤ 16 384); `peerInfo(type: UInt8, data: Data) throws -> Data` (exactly 8192 bytes, zero-padded; data ≤ 8191); `key(from spakeKey: Data) -> SymmetricKey` (HKDF-SHA256, no salt, info `"adb pairing_auth aes-128-gcm key"` without NUL, 16 bytes); `nonce(counter: UInt64) -> AES.GCM.Nonce` (12 bytes, counter little-endian in the first 8, then zeros).
- `public struct PairingClient { public func pair(_ endpoint: WirelessEndpoint, code: PairingCode) async throws(ADBError) -> (guid: String, serverCertificateSHA256: Data) }`:
  1. TLS 1.3 from byte one with Ferry's identity, accepting any server certificate and recording it.
  2. Export 64 bytes with label `"adb-label\0"`.
  3. Password = the code's ASCII digits followed by the export.
  4. SPAKE2 messages in `SPAKE2_MSG` packets.
  5. Send an encrypted `PeerInfo(ADB_RSA_PUB_KEY=0, publicKeyPayload)`, receive `PeerInfo(ADB_DEVICE_GUID=1)`.
  6. A wrong code (decrypt fails) → `.failed("wrong code")`.

- [ ] Tests:
  - `headerGolden` (`header(type: 1, length: 8192 + 16) == [0x01, 0x01, 0x00, 0x00, 0x20, 0x10]`).
  - `oversizeHeaderRejected` (16 385).
  - `nonceSequence` (counters 0, 1, 2^32: first 8 bytes LE, last 4 zero).
  - `hkdfMatchesIndependentVector` (computed with Python `hmac`/`hashlib` HKDF over a fixed 64-byte input; script in the comment).
  - `peerInfoIsExactly8192`.
  - `pairsWithFakeServerAndReturnsGUID`.
  - `wrongCodeFails`.
  - `exporterLabelIncludesNUL` (the fake server derives with a 10-byte label; pairing succeeds only then).
  - The pairing-header and PeerInfo parsers join `ADBWireFuzzTests`.
- [ ] Commit `feat(adb-native): pair with a six-digit code`.

### Task 26: mDNS, pins and Pair with Code natively

**Files:** Create `Sources/ADBNative/TLS/ADBMDNS.swift`, `DevicePins.swift`; modify `NativeWireless.swift` (`pair`, `mdnsServices` native; connect over TLS for paired GUIDs), `ADBWire.swift` (`ADBError.identityChanged`), `FerryIPC/Wireless.swift` (`WirelessFailure.identityChanged`, `.notPaired`; remove `.pairingNeedsADBServer`), `WirelessADB+Connecting.swift`, FerryUI forms, catalog, `help.json`, user guide. Tests: `Tests/ADBNativeTests/DevicePinsTests.swift`, `ADBMDNSTests.swift`, `NativeWirelessTests.swift`.

- [ ] `ADBMDNS`: `NWBrowser` for `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` only. It starts when the Pair with Code form opens, or while a paired device is remembered, and stops when neither holds. A connect instance (`adb-<guid>…`) is used only for a GUID Ferry paired.
- [ ] `DevicePins`: `devicepins.json` in the agent's Application Support. It maps GUID → `{ serial, certificateSHA256 }` (fingerprints only). Pin the certificate Task 21 chose (pairing port, or the first connect-port certificate right after pairing per O-B1). A later connect with a different certificate → `.identityChanged` ("This device's identity changed. Pair it again."); never re-paired silently. Forget removes the pin.
- [ ] Pair flow: pair → auto-connect to the matching connect instance (bounded by `Timing.settle`) → remembered as `.paired`.
- [ ] Tests:
  - `pinStoredOnPairAndChecked`.
  - `mismatchRefusedWithIdentityChanged`.
  - `forgetRemovesPin`.
  - `pinsFileRoundTrip`.
  - `browserOnlyForTheTwoTypes` (the descriptors' types).
  - `connectInstanceForUnpairedGUIDIgnored`.
  - `pairAutoConnects` (fakes).
- [ ] Commit `feat(adb-native): Android 11+ wireless debugging without adb`.

### Task 27: P4 gate — the owner's Android 11+ phone

- [ ] With no `adb` on the Mac: Pair with Code using the phone's code. The device is served over TLS ("Wi-Fi · ADB"); copy a 1 GB file both ways with SHA match; screenshot; logcat.
- [ ] Reboot the phone. Ferry reconnects through mDNS without a new pairing.
- [ ] On the phone, "Revoke USB debugging authorisations", then re-enable wireless debugging. Ferry reports not paired (or, with a new device certificate, "identity changed"). Pair again → served. Record which message appeared.
- [ ] Wrong code → "wrong code" with no pin stored.
- [ ] O-B10 on Android 11+: `shell,v2`, `sync:` and `exec:` behave with Ferry's four-feature banner.
- [ ] Regression on 8.1 (Task 24 changed the handshake): on one LinkRunner, USB browse plus a 100 MB copy with SHA match, then the EtherScope over Connect by Address, same check.
- [ ] Exit (spec §11 P4 gate): an Android 11+ device is available (O4: available). Kill: as Task 21. Shippable state: every v1 goal in the spec, with no install. Record in `docs/TESTING.md`; commit `docs: record native TLS pairing live run`.

---

## Reserve (1 d)

Review rounds and live-run defects. A whole-branch review runs after Task 27, or after the last gate reached if a kill criterion stopped the work.

## Owner rulings on the plan (2026-11-19)

- Open in Terminal: shown only when Ferry can actually provide a shell. With the native engine the shell comes over the ADB protocol (one-shot loopback bridge, Task 16); the row is hidden for any device or state with no shell path. Confirmed.
- Pair with Code between P3 and P4: through an adb server the user already runs; otherwise the form says pairing needs adb for now. Ferry never starts a server. Confirmed.
