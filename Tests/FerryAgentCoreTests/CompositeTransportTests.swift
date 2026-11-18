import DeviceKit
import DeviceKitTestSupport
import Testing

@testable import FerryAgentCore

/// A transport whose scan always fails, as MTP's does when the IOKit registry cannot be read.
private struct FailingTransport: DeviceTransport {
  func scan() async throws(TransportError) -> DeviceScan { throw .io("no registry") }
  func open(_ id: DeviceID) async throws(TransportError) -> any DeviceSession {
    throw .deviceNotFound(id)
  }
  func park(_ id: DeviceID) async {}
  func unpark(_ id: DeviceID) async {}
}

/// The same unit as each transport names it: MTP by its USB product name, ADB by
/// `ro.product.model` and a SoC vendor.
func viaMTP(_ serial: String) -> FakeDevice {
  FakeDevice(
    info: DeviceInfo(
      id: DeviceID(serial: serial), manufacturer: "NetAlly", model: "LinkRunner-100G"),
    storages: [neutralStorage(serial)])
}

func viaADB(_ serial: String) -> FakeDevice {
  FakeDevice(
    info: DeviceInfo(id: DeviceID(serial: serial), manufacturer: "", model: "LinkRunner 100G"),
    storages: [neutralStorage(serial)])
}

func neutralStorage(_ serial: String) -> StorageInfo {
  StorageInfo(
    id: StorageID(device: DeviceID(serial: serial), key: StorageKey.internal),
    description: "Internal shared storage", capacity: 1 << 30, free: 1 << 29)
}

@Suite(.timeLimit(.minutes(1)))
struct CompositeTransportTests {
  let mtpDevice = viaMTP("S1")
  let adbDevice = viaADB("S1")
  var id: DeviceID { mtpDevice.info.id }

  /// Review Focus 2: one unit seen by both is one entry, opened only over ADB.
  @Test func aDeviceBothSeeIsOneEntryServedOverADBUnderItsMTPName() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    let composite = CompositeTransport(mtp: mtp, adb: adb)

    let scan = try await composite.scan()
    #expect(scan.devices == [mtpDevice.info])
    #expect(scan.method(of: id) == .usbADB)
    let session = try await composite.open(id)
    #expect(session.info == adbDevice.info)
    #expect(await adb.openCount(of: id) == 1)
    #expect(await mtp.openCount(of: id) == 0)
  }

  @Test func anADBOnlyDeviceKeepsItsADBNameAndRoute() async throws {
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    let composite = CompositeTransport(mtp: FakeTransport(devices: []), adb: adb)

    let scan = try await composite.scan()
    #expect(scan.devices == [adbDevice.info])
    #expect(scan.method(of: id) == .wifiADB)
  }

  /// Once seen over MTP, a device keeps its MTP name, so its Finder location is not renamed when
  /// the cable is pulled and the network takes over.
  @Test func theMTPNameOutlastsMTP() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    let composite = CompositeTransport(mtp: mtp, adb: adb)
    _ = try await composite.scan()

    await mtp.detach(id)
    await adb.setMethod(.wifiADB, for: id)
    let scan = try await composite.scan()
    #expect(scan.devices == [mtpDevice.info])
    #expect(scan.method(of: id) == .wifiADB)
  }

  @Test func aDeviceOnlyMTPSeesIsServedOverMTP() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let composite = CompositeTransport(mtp: mtp, adb: FakeTransport(devices: [], method: .usbADB))

    let scan = try await composite.scan()
    #expect(scan.devices == [mtpDevice.info])
    #expect(scan.method(of: id) == .usbFileTransfer)
    _ = try await composite.open(id)
    #expect(await mtp.openCount(of: id) == 1)
  }

  /// USB debugging not allowed yet: MTP serves the device if it can; otherwise the device is
  /// listed as not sharing, reached over ADB, so the menu can say to allow debugging.
  @Test func anUnauthorizedDeviceIsLeftToMTP() async throws {
    let unauthorized = DeviceInfo(id: id, manufacturer: "Unknown", model: "LinkRunner 100G")
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.attachWithoutFileTransfer(unauthorized)

    let served = try await CompositeTransport(mtp: FakeTransport(devices: [mtpDevice]), adb: adb)
      .scan()
    #expect(served.devices == [mtpDevice.info])
    #expect(served.notSharing.isEmpty)
    #expect(served.method(of: id) == .usbFileTransfer)

    let alone = try await CompositeTransport(mtp: FakeTransport(devices: []), adb: adb).scan()
    #expect(alone.devices.isEmpty)
    #expect(alone.notSharing == [unauthorized])
    #expect(alone.method(of: id) == .usbADB)
  }

  /// Ejecting parks the device in both, and a device either reports ejected is not offered as
  /// usable by the other: MTP may not hold it, and then cannot park it.
  @Test func ejectedInEitherIsEjected() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    let composite = CompositeTransport(mtp: mtp, adb: adb)
    _ = try await composite.scan()

    await adb.park(id)
    let scan = try await composite.scan()
    #expect(scan.devices.isEmpty)
    #expect(scan.ejected == [mtpDevice.info])
    await #expect(throws: TransportError.deviceNotFound(id)) {
      _ = try await composite.open(id)
    }

    await composite.park(id)
    #expect(await mtp.isParked(id))
    await composite.unpark(id)
    #expect(await !mtp.isParked(id))
    #expect(await !adb.isParked(id))
    #expect(try await composite.scan().devices == [mtpDevice.info])
  }

  @Test func oneTransportFailingLeavesTheOther() async throws {
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    let scan = try await CompositeTransport(mtp: FailingTransport(), adb: adb).scan()
    #expect(scan.devices == [adbDevice.info])

    await #expect(throws: TransportError.io("no registry")) {
      _ = try await CompositeTransport(mtp: FailingTransport(), adb: FailingTransport()).scan()
    }
  }

  @Test func busyAndRescanCombine() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    await mtp.setHeldByAnotherApp(id, true)
    await mtp.setRescanAfter(.seconds(3))
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.setRescanAfter(.seconds(2))

    let scan = try await CompositeTransport(mtp: mtp, adb: adb).scan()
    #expect(scan.busy.map(\.id) == [FakeTransport.busyID(for: id)])
    #expect(scan.rescanAfter == .seconds(2))
  }

  /// MTP names a device without file transfer by its USB location, and ADB names it by its
  /// serial: nothing ties the two together, so such a unit is listed twice. Pinned so a fix
  /// (reading the USB serial from the registry) is a deliberate change.
  @Test func aDeviceWithoutFileTransferButWithADBIsListedTwice() async throws {
    let usbOnly = DeviceInfo(
      id: DeviceID(serial: "usb-0-3"), manufacturer: "NetAlly", model: "LinkRunner-100G")
    let mtp = FakeTransport(devices: [])
    await mtp.attachWithoutFileTransfer(usbOnly)
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)

    let scan = try await CompositeTransport(mtp: mtp, adb: adb).scan()
    #expect(scan.devices == [adbDevice.info])
    #expect(scan.notSharing == [usbOnly])
  }
}
