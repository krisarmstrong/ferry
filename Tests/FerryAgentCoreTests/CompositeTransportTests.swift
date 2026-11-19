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

  /// Any USB route beats a network one: a network device answering with the serial of a unit on
  /// the cable never takes that unit over.
  @Test func aUSBDeviceIsNotServedOverTheNetwork() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    let composite = CompositeTransport(mtp: mtp, adb: adb)

    let scan = try await composite.scan()
    #expect(scan.devices == [mtpDevice.info])
    #expect(scan.method(of: id) == .usbFileTransfer)
    _ = try await composite.open(id)
    #expect(await mtp.openCount(of: id) == 1)
    #expect(await adb.openCount(of: id) == 0)
  }

  @Test(arguments: ConnectionMethod.allCases)
  func preferenceIsUSBADBThenMTPThenNetwork(_ method: ConnectionMethod) {
    let order: [ConnectionMethod] = [.usbADB, .usbFileTransfer, .wifiADB]
    let rank = order.firstIndex(of: method)!
    for (index, other) in order.enumerated() {
      #expect(method.isPreferred(over: other) == (rank < index))
    }
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

  /// MTP names a device without file transfer by its USB serial, which is ADB's `ro.serialno`:
  /// a unit with file transfer off but ADB on is one device, served over ADB.
  @Test func aDeviceWithoutFileTransferButWithADBIsOneDevice() async throws {
    let mtp = FakeTransport(devices: [])
    await mtp.attachWithoutFileTransfer(mtpDevice.info)
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)

    let scan = try await CompositeTransport(mtp: mtp, adb: adb).scan()
    #expect(scan.devices == [mtpDevice.info])
    #expect(scan.notSharing.isEmpty)
    #expect(scan.method(of: id) == .usbADB)
  }

  /// File transfer off and USB debugging not allowed yet: one not-sharing entry, not two.
  @Test func aDeviceNotSharingEitherWayIsListedOnce() async throws {
    let mtp = FakeTransport(devices: [])
    await mtp.attachWithoutFileTransfer(mtpDevice.info)
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.attachWithoutFileTransfer(adbDevice.info)

    let scan = try await CompositeTransport(mtp: mtp, adb: adb).scan()
    #expect(scan.notSharing == [mtpDevice.info])
  }

  /// A network device waiting for "Allow" is not a device yet: its `host:port` names no unit.
  /// It is passed on for the menu to say what to do.
  @Test func networkDevicesAwaitingAuthorizationArePassedOn() async throws {
    let adb = FakeTransport(devices: [], method: .usbADB)
    await adb.awaitAuthorization("192.0.2.31:5555")
    let scan = try await CompositeTransport(mtp: FakeTransport(devices: []), adb: adb).scan()
    #expect(scan.notSharing.isEmpty && scan.devices.isEmpty)
    #expect(scan.awaitingAuthorization == ["192.0.2.31:5555"])
  }

  // MARK: USB presence in any state blocks the network (C1)

  /// A cabled unit MTP cannot serve (file transfer off, held by another app, ejected) still keeps
  /// a network device with its serial from serving it.
  @Test(arguments: ["notSharing", "busy", "ejected"])
  func aUSBDeviceMTPCannotServeIsNotServedOverTheNetwork(_ state: String) async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    switch state {
    case "notSharing":
      await mtp.detach(id)
      await mtp.attachWithoutFileTransfer(mtpDevice.info)
    case "busy":
      await mtp.setHeldByAnotherApp(id, true)
      await mtp.setBusyKeepsSerial(true)
    default:
      _ = try await mtp.open(id)
      await mtp.park(id)
    }
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    let composite = CompositeTransport(mtp: mtp, adb: adb)

    let scan = try await composite.scan()
    #expect(scan.devices.isEmpty)
    #expect((scan.busy + scan.notSharing + scan.ejected).map(\.id) == [id])
    await #expect(throws: TransportError.deviceNotFound(id)) {
      _ = try await composite.open(id)
    }
    #expect(await adb.openCount(of: id) == 0)
  }

  /// adb itself sees the unit on USB (unauthorised, offline): the network does not serve it.
  @Test func aUSBRouteADBReportsBlocksTheNetwork() async throws {
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    await adb.presentOverUSB(id)
    let scan = try await CompositeTransport(mtp: FakeTransport(devices: []), adb: adb).scan()
    #expect(scan.devices.isEmpty)
  }

  // MARK: A failed scan is not an empty one (I1)

  /// One failed MTP scan leaves MTP's last view standing, so a cabled unit is not handed to the
  /// network; a successful scan that no longer lists it does.
  @Test func aFailedMTPScanKeepsItsLastView() async throws {
    let mtp = FakeTransport(devices: [mtpDevice])
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    let composite = CompositeTransport(mtp: mtp, adb: adb)
    #expect(try await composite.scan().method(of: id) == .usbFileTransfer)

    await mtp.failScans(with: .io("registry"))
    let failed = try await composite.scan()
    #expect(failed.devices == [mtpDevice.info])
    #expect(failed.method(of: id) == .usbFileTransfer)
    #expect(failed.rescanAfter == CompositeTransport.staleRetry)

    await mtp.failScans(with: nil)
    await mtp.detach(id)
    #expect(try await composite.scan().method(of: id) == .wifiADB)
  }

  /// Until MTP has scanned once, Ferry cannot know which units are on the cable: the network
  /// serves nothing, so a unit on USB with debugging off is not served over Wi-Fi meanwhile.
  @Test func noNetworkRouteIsServedBeforeTheFirstMTPScan() async throws {
    let mtp = FakeTransport(devices: [])
    await mtp.failScans(with: .io("registry"))
    let adb = FakeTransport(devices: [adbDevice], method: .usbADB)
    await adb.setMethod(.wifiADB, for: id)
    let composite = CompositeTransport(mtp: mtp, adb: adb)
    let failed = try await composite.scan()
    #expect(failed.devices.isEmpty)
    #expect(failed.rescanAfter == CompositeTransport.staleRetry)

    await mtp.failScans(with: nil)
    #expect(try await composite.scan().method(of: id) == .wifiADB)
  }
}
