import DeviceKit
import Foundation
import Security
import Testing

@testable import FerryIPC

private let device = DeviceID(serial: "R58N12345")
private let domain = "R58N12345|Internal|vol0"

/// A distinct number per case, so a new case fails to compile here until a fixture covers it.
private func tag(_ request: AgentRequest) -> Int {
  switch request {
  case .status: 0
  case .recheck: 1
  case .eject: 2
  case .removeAllDomains: 3
  case .item: 4
  case .list: 5
  case .fetch: 6
  case .create: 7
  case .rename: 8
  case .move: 9
  case .replaceContents: 10
  case .delete: 11
  case .changes: 12
  case .workingSet: 13
  case .refresh: 14
  case .recheckADB: 15
  case .connectAddress: 16
  case .pair: 17
  case .connectWireless: 18
  case .enableWireless: 19
  case .forgetWireless: 20
  case .confirmWireless: 21
  case .ignoreWireless: 22
  case .installAPK: 23
  case .screenshot: 24
  case .startRecording: 25
  case .stopRecording: 26
  case .saveRecording: 27
  case .discardRecording: 28
  case .startLogcat: 29
  case .stopLogcat: 30
  case .forwards: 31
  case .addForward: 32
  case .removeForward: 33
  case .deviceInfo: 34
  case .shellTarget: 35
  case .sendFile: 36
  case .devices: 37
  }
}

/// One of each request, for tests that check every case.
func requests() -> [AgentRequest] {
  let photo = ItemID.random()
  let camera = ItemID.random()
  var all: [AgentRequest] = [
    .status, .recheck(device), .refresh(device), .eject(device), .recheckADB,
  ]
  all.append(.removeAllDomains)
  all += [.item(domain: domain, id: photo), .list(domain: domain, folder: .root)]
  all.append(.list(domain: domain, folder: camera, page: Data("next".utf8)))
  all.append(.fetch(domain: domain, id: photo))
  all.append(.create(domain: domain, parent: camera, name: "photo.jpg", isFolder: false))
  all.append(.create(domain: domain, parent: .root, name: "Camera", isFolder: true))
  all.append(.rename(domain: domain, id: photo, to: "renamed.jpg"))
  all.append(.move(domain: domain, id: photo, toFolder: .root))
  let version = ContentVersion(
    RemoteItem(path: .root, kind: .file, size: 3, modified: Date(timeIntervalSince1970: 7)))
  all.append(.replaceContents(domain: domain, id: photo, base: nil, onConflict: .keepBoth))
  all.append(.replaceContents(domain: domain, id: photo, base: version, onConflict: .fail))
  all.append(.delete(domain: domain, id: camera, base: nil, recursive: false))
  all.append(.delete(domain: domain, id: camera, base: version, recursive: true))
  all += [.changes(domain: domain, since: nil), .changes(domain: domain, since: Data([1, 2, 3]))]
  all += [.workingSet(domain: domain, page: nil), .workingSet(domain: domain, page: Data([7]))]
  let address = WirelessEndpoint(parsing: "192.0.2.31")!
  all += [.connectAddress(address), .pair(address, code: PairingCode("482913")!)]
  all += [.connectWireless(device), .enableWireless(device), .forgetWireless(device)]
  all += [
    .confirmWireless(UnconfirmedAddress(address: address, id: device, name: "EtherScope nXG")),
    .ignoreWireless(address),
  ]
  all += [
    .installAPK(device, name: "Ferry Test.apk"), .screenshot(device), .startRecording(device),
    .stopRecording(device), .saveRecording(device), .discardRecording(device),
  ]
  all += developerRequests()
  all += [.sendFile(device, name: "Report.pdf"), .devices]
  return all
}

private func tag(_ error: TransportError) -> Int {
  switch error {
  case .noDeviceConnected: 0
  case .deviceNotFound: 1
  case .noStorage: 2
  case .storageNotFound: 3
  case .deviceBusy: 4
  case .deviceLocked: 5
  case .deviceDisconnected: 6
  case .notFound: 7
  case .unknownItem: 8
  case .alreadyExists: 9
  case .invalidName: 10
  case .unsupported: 11
  case .insufficientSpace: 12
  case .fileTooLargeForStorage: 13
  case .sizeMismatch: 14
  case .nameChangedByDevice: 15
  case .cancelled: 16
  case .io: 17
  case .downloadSizeMismatch: 18
  case .directoryNotEmpty: 19
  case .changedOnDevice: 20
  case .macDiskFull: 21
  case .folderTooDeep: 22
  case .readOnly: 23
  case .agentNotResponding: 24
  case .pageExpired: 25
  }
}

private func errors() throws -> [TransportError] {
  let photo = try RemotePath("/DCIM/Camera/photo.jpg")
  var all: [TransportError] = [.noDeviceConnected, .deviceNotFound(device), .noStorage]
  all += [.storageNotFound("SD card"), .deviceBusy, .deviceLocked, .deviceDisconnected]
  all += [
    .notFound(photo), .unknownItem, .alreadyExists(photo), .invalidName("a/b"),
    .unsupported("copy"),
  ]
  all += [.insufficientSpace(needed: 10, free: 5), .fileTooLargeForStorage(size: 5_000_000_000)]
  all += [.sizeMismatch(expected: 10, actual: 9), .cancelled, .io("read failed")]
  all.append(.nameChangedByDevice(requested: "Ä.txt", actual: "A.txt"))
  all.append(.downloadSizeMismatch(listed: 10, received: 9))
  all += [.directoryNotEmpty(photo), .changedOnDevice(photo), .macDiskFull(needed: 9, free: 1)]
  all += [.folderTooDeep(photo), .readOnly(photo), .agentNotResponding, .pageExpired]
  return all
}

private func tag(_ response: AgentResponse) -> Int {
  switch response {
  case .status: 0
  case .entry: 1
  case .done: 3
  case .failure: 4
  case .changes: 5
  case .page: 2
  case .removed: 6
  case .keptOnDevice: 7
  case .wireless: 8
  case .toolFailed: 9
  case .forwards: 10
  case .deviceInfo: 11
  case .shellTarget: 12
  case .devices: 13
  }
}

private func responses() throws -> [AgentResponse] {
  let item = ProviderEntry(
    id: .random(), parent: .random(),
    item: RemoteItem(
      path: try RemotePath("/DCIM/Camera/photo.jpg"), kind: .file, size: 1_234,
      modified: Date(timeIntervalSince1970: 1_700_000_000)))
  let root = ProviderEntry(
    id: .root, parent: .root,
    item: RemoteItem(path: .root, kind: .folder, size: 0, modified: .distantPast))
  let storage = StorageInfo(
    id: StorageID(device: device, key: "Internal|vol0"), description: "Internal",
    capacity: 1_000, free: 900)
  let ready = AttachedDevice(
    info: DeviceInfo(id: device, manufacturer: "NetAlly", model: "EtherScope"),
    state: .ready([storage]), method: .usbFileTransfer)
  let locked = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "B"), manufacturer: "Pixel", model: "8"),
    state: .failed(.deviceLocked), method: .usbFileTransfer)
  var all: [AgentResponse] = [
    .status(StatusReport(devices: [ready, locked], provider: .enabled)),
    .status(StatusReport(devices: [], provider: .noDomains)),
    .status(
      StatusReport(
        devices: [], provider: .enabled, awaitingAuthorization: ["192.0.2.31:5555"])),
  ]
  for adb in [nil, ADBStatus.available, .notInstalled, .serverDown] {
    all.append(
      .status(
        StatusReport(
          devices: [ready], provider: .enabled, adbStatus: adb,
          awaitingUSBDebugging: [device])))
  }
  all += [
    .entry(item), .entry(root), .page(entries: [item, root], next: nil),
    .page(entries: [], next: nil),
  ]
  all.append(.keptOnDevice(item))
  all += [.done, .failure(.deviceDisconnected)]
  all.append(.changes(anchor: Data([9]), updated: [item], deleted: [.random()], expired: false))
  all.append(.changes(anchor: Data(), updated: [], deleted: [], expired: true))
  all += [.page(entries: [item, root], next: Data([7])), .page(entries: [], next: nil)]
  all += [.removed(preserved: []), .removed(preserved: [URL(filePath: "/tmp/Ferry unsent")])]
  return all + (try wirelessResponses()) + toolResponses()
}

private func toolResponses() -> [AgentResponse] {
  var all: [AgentResponse] = []
  for failure: ToolFailure in [
    .notOverADB, .notAnAPK, .apkTooLarge, .installFailed("INSTALL_FAILED_OLDER_SDK"),
    .alreadyRecording, .notRecording, .noImage, .recordingFailed("no encoder"), .cannotSave,
    .recordingTooLarge, .recordingStalled, .recordingBusy, .invalidPort, .adbNotFound,
    .forwardNotFound,
    .forwardFailed("cannot bind listener: Address already in use"),
  ] {
    all.append(.toolFailed(failure))
  }
  all.append(
    .status(
      StatusReport(
        devices: [], provider: .enabled,
        recordings: [
          ActiveRecording(
            device: device, started: Date(timeIntervalSince1970: 1_763_503_767), stopping: true),
          ActiveRecording(
            device: device, started: Date(timeIntervalSince1970: 1_763_503_800), stopping: false,
            finished: true),
        ])))
  all += [
    .forwards([]), .forwards([PortForward(local: 8080, remote: 80)]),
    .deviceInfo(
      AndroidDeviceInfo(
        model: "LinkRunner G2", androidVersion: "8.1.0", build: "OPM1", serial: "R58N12345",
        battery: .init(level: 87, state: .charging),
        addresses: [.init(interface: "eth0", address: "192.0.2.31")],
        storage: .init(used: 5, free: 10))),
    .deviceInfo(
      AndroidDeviceInfo(
        model: "", androidVersion: "", build: "", serial: "", battery: nil, addresses: [],
        storage: nil)),
  ]
  if let target = ShellTarget(adb: "/opt/homebrew/bin/adb", serial: "192.0.2.31:5555") {
    all.append(.shellTarget(target))
  }
  all.append(
    .devices([
      DeviceSummary(id: device, name: "LinkRunner 10G", method: .usbADB, ready: true),
      DeviceSummary(id: DeviceID(serial: "B"), name: "", method: .usbFileTransfer, ready: false),
    ]))
  all.append(.devices([]))
  return all
}

private func wirelessResponses() throws -> [AgentResponse] {
  let address = try #require(WirelessEndpoint(parsing: "192.0.2.31:5555"))
  var all: [AgentResponse] = []
  all += [.wireless(.connected), .wireless(.awaitingAllow(address)), .wireless(.needsNetwork)]
  all.append(.wireless(.needsConfirmation(address)))
  for failure: WirelessFailure in [
    .adbUnavailable, .notOverUSB, .notRemembered, .noConnectService, .otherDevice,
    .adb("failed to connect"), .unidentified, .offerChanged, .pairingNeedsAddress, .deviceInUse,
    .localNetworkDenied, .serverRestarted,
  ] {
    all.append(.wireless(.failed(failure)))
  }
  all.append(
    .status(
      StatusReport(
        devices: [], provider: .enabled,
        remembered: [
          RememberedDevice(id: device, name: "EtherScope nXG", addresses: [address])
        ],
        unconfirmed: [UnconfirmedAddress(address: address, id: device, name: "EtherScope nXG")])))
  return all
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Test func everyRequestRoundTripsJSON() throws {
  #expect(Set(requests().map(tag)) == Set(0...37))
  for request in requests() {
    #expect(try roundTrip(request) == request)
  }
}

@Test func everyErrorRoundTripsJSON() throws {
  #expect(Set(try errors().map(tag)) == Set(0...25))
  for error in try errors() {
    #expect(try roundTrip(AgentResponse.failure(error)) == .failure(error))
  }
}

@Test func everyResponseRoundTripsJSON() throws {
  #expect(Set(try responses().map(tag)) == Set(0...13))
  for response in try responses() {
    #expect(try roundTrip(response) == response)
  }
}

private struct UnreachableHandler: AgentHandling {
  func text(for refusal: Refusal) -> String { refusal.testText }

  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    Issue.record("handler called with \(request)")
    return .done
  }
}

private func reply(to data: Data) async throws -> AgentResponse {
  let service = AgentService(handler: UnreachableHandler(), role: nil)
  let (replies, continuation) = AsyncStream.makeStream(of: Data.self)
  service.send(data, id: "test", file: nil) { continuation.yield($0) }
  var iterator = replies.makeAsyncIterator()
  let data = try #require(await iterator.next())
  return try JSONDecoder().decode(AgentResponse.self, from: data)
}

/// A pairing code or an address that is not one never decodes, so the agent never sees it.
@Test(arguments: [("482913", "12a456"), ("192.0.2.31", "-s"), ("37123", "0")])
func invalidWirelessRequestsReplyBadRequest(valid: String, invalid: String) async throws {
  let request = AgentRequest.pair(
    try #require(WirelessEndpoint(parsing: "192.0.2.31:37123")),
    code: try #require(
      PairingCode("482913")))
  let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
  #expect(json.contains(valid))
  let tampered = json.replacing(valid, with: invalid)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(AgentRequest.self, from: Data(tampered.utf8))
  }
  #expect(try await reply(to: Data(tampered.utf8)) == .failure(.io("bad request")))
}

/// Wireless requests change what this Mac connects to: only the app may send them.
@Test func wirelessRequestsAreTheAppsAlone() throws {
  let address = try #require(WirelessEndpoint(parsing: "192.0.2.31"))
  let code = try #require(PairingCode("482913"))
  for request: AgentRequest in [
    .connectAddress(address), .pair(address, code: code), .connectWireless(device),
    .enableWireless(device), .forgetWireless(device),
    .confirmWireless(UnconfirmedAddress(address: address, id: device, name: "EtherScope nXG")),
    .ignoreWireless(address),
  ] {
    #expect(ClientRole.app.allows(request))
    #expect(!ClientRole.provider.allows(request))
  }
}

/// The tools install apps on and record the screens of the user's devices: the app's alone.
@Test func toolRequestsAreTheAppsAlone() {
  for request: AgentRequest in [
    .installAPK(device, name: "a.apk"), .screenshot(device), .startRecording(device),
    .stopRecording(device), .saveRecording(device), .discardRecording(device),
  ] {
    #expect(ClientRole.app.allows(request))
    #expect(!ClientRole.provider.allows(request))
  }
}

@Test func undecodableRequestRepliesBadRequest() async throws {
  #expect(try await reply(to: Data("not json".utf8)) == .failure(.io("bad request")))
}

/// Only `root` and the agent's UUIDs are identifiers, so a client cannot name an item by path.
@Test(arguments: ["/DCIM", "/DCIM/../..", "", "ROOT", "0e9b1e0a-9c1f-4a43-9f43-0f1f1a2b3c4d"])
func nonIdentifierRepliesBadRequest(_ folder: String) async throws {
  let data = Data(#"{"list":{"domain":"d","folder":"\#(folder)"}}"#.utf8)
  #expect(try await reply(to: data) == .failure(.io("bad request")))
}

@Test func identifiersAreRootOrUppercaseUUIDs() throws {
  let id = ItemID.random()
  #expect(ItemID(rawValue: id.rawValue) == id)
  #expect(ItemID(rawValue: "root") == .root)
  #expect(ItemID(rawValue: id.rawValue.lowercased()) == nil)
  #expect(try roundTrip(id) == id)
}

private let requirements =
  [FerryIdentity(teamID: "X6JWYP43HG")].compactMap { $0 }
  .flatMap { identity in
    ClientRole.allCases.map(identity.requirement(for:)) + [identity.agentRequirement]
  }

@Test(arguments: requirements)
func requirementCompiles(_ text: String) throws {
  var requirement: SecRequirement?
  #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
  #expect(requirement != nil)
}
