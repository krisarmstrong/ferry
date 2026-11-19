import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryAgentCore

/// Send to <device> from Finder: a file goes into `Download/` on the device's internal storage,
/// through the domain's writer, and never over a file already there.
@Suite(.timeLimit(.minutes(1)))
struct AgentSendFileTests {
  private func ready(keys: [String] = [StorageKey.internal]) async throws -> (
    AgentHarness, FakeDevice
  ) {
    let device = await makeDevice("A", keys: keys)
    let harness = try AgentHarness(devices: [device])
    _ = await harness.manager.waitForCalls(keys.count)
    return (harness, device)
  }

  @Test func aFileGoesIntoDownloadOnTheInternalStorage() async throws {
    let (harness, device) = try await ready()
    defer { harness.finish() }
    let storage = storageID(device, StorageKey.internal)
    let report = try harness.readable("Report.pdf", "report")

    let response = await harness.service.handle(
      .sendFile(device.info.id, name: "Report.pdf"), file: report)

    guard case .entry(let entry) = response else {
      Issue.record("expected an entry, got \(response)")
      return
    }
    let sent = try path("/Download/Report.pdf")
    #expect(entry.item.path == sent)
    #expect(await device.contents(of: sent, in: storage) == Data("report".utf8))
    // Recorded in the domain's table and signalled, so Finder's location shows it.
    let domain = domainID(device, StorageKey.internal)
    #expect(entry.id == (try await harness.id(sent, in: domain)))
    #expect(await harness.manager.calls.contains(.signal(domain)))
  }

  @Test func aTakenNameGetsAConflictCopyAndTheDevicesFileStays() async throws {
    let (harness, device) = try await ready()
    defer { harness.finish() }
    let storage = storageID(device, StorageKey.internal)
    let taken = try path("/Download/Report.pdf")
    try await device.seed(taken, in: storage, contents: Data("device".utf8))

    let response = await harness.service.handle(
      .sendFile(device.info.id, name: "Report.pdf"),
      file: try harness.readable("Report.pdf", "mac"))

    guard case .entry(let entry) = response else {
      Issue.record("expected an entry, got \(response)")
      return
    }
    let copy = try path("/Download/Report (conflict from Mac).pdf")
    #expect(entry.item.path == copy)
    #expect(await device.contents(of: taken, in: storage) == Data("device".utf8))
    #expect(await device.contents(of: copy, in: storage) == Data("mac".utf8))
  }

  /// The internal storage is the one keyed `internal`, wherever the device lists it.
  @Test func theInternalStorageIsChosenOverACard() async throws {
    let card = StorageKey.volume("1234-ABCD")
    let (harness, device) = try await ready(keys: [card, StorageKey.internal])
    defer { harness.finish() }

    _ = await harness.service.handle(
      .sendFile(device.info.id, name: "a.txt"), file: try harness.readable("a.txt", "a"))

    let sent = try path("/Download/a.txt")
    #expect(await device.contents(of: sent, in: storageID(device, StorageKey.internal)) != nil)
    #expect(await device.contents(of: sent, in: storageID(device, card)) == nil)
  }

  /// An MTP device whose primary storage did not map to `internal` keeps its first storage, the
  /// one MTP lists as primary.
  @Test func withoutAnInternalKeyTheFirstStorageIsUsed() async throws {
    let (harness, device) = try await ready(keys: [internalKey, cardKey])
    defer { harness.finish() }

    _ = await harness.service.handle(
      .sendFile(device.info.id, name: "a.txt"), file: try harness.readable("a.txt", "a"))

    let sent = try path("/Download/a.txt")
    #expect(await device.contents(of: sent, in: storageID(device, internalKey)) != nil)
    #expect(await device.contents(of: sent, in: storageID(device, cardKey)) == nil)
  }

  @Test func aDeviceThatIsNotReadyIsDisconnected() async throws {
    let (harness, _) = try await ready()
    defer { harness.finish() }

    let response = await harness.service.handle(
      .sendFile(DeviceID(serial: "GONE"), name: "a.txt"),
      file: try harness.readable("a.txt", "a"))

    #expect(response == .failure(.deviceDisconnected))
  }

  /// The name is one path component, as for any upload; a send needs its file.
  @Test func aBadNameOrNoFileIsRefused() async throws {
    let (harness, device) = try await ready()
    defer { harness.finish() }

    let escaping = await harness.service.handle(
      .sendFile(device.info.id, name: "../a.txt"), file: try harness.readable("a.txt", "a"))
    let noFile = await harness.service.handle(
      .sendFile(device.info.id, name: "a.txt"), file: nil)

    #expect(escaping == .failure(.invalidName("../a.txt")))
    #expect(noFile == .failure(.io("bad request")))
    #expect(
      await device.allPaths(in: storageID(device, StorageKey.internal)).allSatisfy {
        $0.name != "a.txt"
      })
  }
}
