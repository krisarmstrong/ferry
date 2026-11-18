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
  }
}

private func requests() throws -> [AgentRequest] {
  let photo = try RemotePath("/DCIM/Camera/photo.jpg")
  let camera = try RemotePath("/DCIM/Camera")
  var all: [AgentRequest] = [.status, .recheck(device), .eject(device), .removeAllDomains]
  all += [.item(domain: domain, path: photo), .list(domain: domain, folder: .root)]
  all.append(.fetch(domain: domain, path: photo))
  all.append(.create(domain: domain, path: photo, isFolder: false))
  all.append(.create(domain: domain, path: camera, isFolder: true))
  all.append(.rename(domain: domain, path: photo, to: "renamed.jpg"))
  all.append(.move(domain: domain, path: photo, toFolder: .root))
  all.append(.replaceContents(domain: domain, path: photo))
  all.append(.delete(domain: domain, path: camera))
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
  case .alreadyExists: 8
  case .invalidName: 9
  case .unsupported: 10
  case .insufficientSpace: 11
  case .fileTooLargeForStorage: 12
  case .sizeMismatch: 13
  case .nameChangedByDevice: 14
  case .cancelled: 15
  case .io: 16
  }
}

private func errors() throws -> [TransportError] {
  let photo = try RemotePath("/DCIM/Camera/photo.jpg")
  var all: [TransportError] = [.noDeviceConnected, .deviceNotFound(device), .noStorage]
  all += [.storageNotFound("SD card"), .deviceBusy, .deviceLocked, .deviceDisconnected]
  all += [.notFound(photo), .alreadyExists(photo), .invalidName("a/b"), .unsupported("copy")]
  all += [.insufficientSpace(needed: 10, free: 5), .fileTooLargeForStorage(size: 5_000_000_000)]
  all += [.sizeMismatch(expected: 10, actual: 9), .cancelled, .io("read failed")]
  all.append(.nameChangedByDevice(requested: "Ä.txt", actual: "A.txt"))
  return all
}

private func tag(_ response: AgentResponse) -> Int {
  switch response {
  case .status: 0
  case .item: 1
  case .items: 2
  case .done: 3
  case .failure: 4
  }
}

private func responses() throws -> [AgentResponse] {
  let item = RemoteItem(
    path: try RemotePath("/DCIM/Camera/photo.jpg"), kind: .file, size: 1_234,
    modified: Date(timeIntervalSince1970: 1_700_000_000))
  let storage = StorageInfo(
    id: StorageID(device: device, key: "Internal|vol0"), description: "Internal",
    capacity: 1_000, free: 900)
  let ready = AttachedDevice(
    info: DeviceInfo(id: device, manufacturer: "NetAlly", model: "EtherScope"),
    state: .ready([storage]))
  let locked = AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: "B"), manufacturer: "Pixel", model: "8"),
    state: .failed(.deviceLocked))
  var all: [AgentResponse] = [.status(devices: [ready, locked], providerEnabled: true)]
  all += [.item(item), .items([item, item]), .items([]), .done, .failure(.deviceDisconnected)]
  return all
}

private func roundTrip<T: Codable>(_ value: T) throws -> T {
  try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
}

@Test func everyRequestRoundTripsJSON() throws {
  #expect(Set(try requests().map(tag)) == Set(0...11))
  for request in try requests() {
    #expect(try roundTrip(request) == request)
  }
}

@Test func everyErrorRoundTripsJSON() throws {
  #expect(Set(try errors().map(tag)) == Set(0...16))
  for error in try errors() {
    #expect(try roundTrip(AgentResponse.failure(error)) == .failure(error))
  }
}

@Test func everyResponseRoundTripsJSON() throws {
  #expect(Set(try responses().map(tag)) == Set(0...4))
  for response in try responses() {
    #expect(try roundTrip(response) == response)
  }
}

private struct UnreachableHandler: AgentHandling {
  func handle(_ request: AgentRequest, file: FileHandle?) async -> AgentResponse {
    Issue.record("handler called with \(request)")
    return .done
  }
}

private func reply(to data: Data) async throws -> AgentResponse {
  let service = AgentService(handler: UnreachableHandler())
  let (replies, continuation) = AsyncStream.makeStream(of: Data.self)
  service.send(data, file: nil) { continuation.yield($0) }
  var iterator = replies.makeAsyncIterator()
  let data = try #require(await iterator.next())
  return try JSONDecoder().decode(AgentResponse.self, from: data)
}

@Test func undecodableRequestRepliesBadRequest() async throws {
  #expect(try await reply(to: Data("not json".utf8)) == .failure(.io("bad request")))
}

@Test func traversingPathRepliesBadRequest() async throws {
  let data = Data(#"{"list":{"domain":"d","folder":"/DCIM/../.."}}"#.utf8)
  #expect(try await reply(to: data) == .failure(.io("bad request")))
}

private let requirements =
  [AgentListenerDelegate.ferryClientRequirement]
  + [AgentListenerDelegate.agentRequirement]

@Test(arguments: requirements)
func requirementCompiles(_ text: String) throws {
  var requirement: SecRequirement?
  #expect(SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess)
  #expect(requirement != nil)
}
