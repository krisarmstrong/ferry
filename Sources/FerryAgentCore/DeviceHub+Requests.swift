import DeviceKit
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "DeviceHub")

// MARK: The user's requests

extension DeviceHub {
  /// The user's Check Again: re-reads a held device's storages, for instance after file transfer
  /// was turned on. A device the hub does not hold (busy, failed, not sharing, ejected) is
  /// offered to the transport again and the bus scanned.
  public func recheck(_ id: DeviceID) async {
    guard let entry = entries[id] else { return }
    guard case .held = entry.holding else {
      ejected.remove(id)
      backoff[id] = nil
      await transport.unpark(id)
      await reconcile()
      return
    }
    await recheckHeld(id)
  }

  /// The user's Check again for adb: looks for `adb` and starts its server, then scans, so the
  /// next status shows what that found.
  public func recheckADB() async {
    await transport.startADBServer()
    await reconcile()
  }

  /// Closes the device's session once the requests on it have finished. It stays listed as
  /// `.ejected` until it is unplugged or mounted again: the transport is told to leave it alone
  /// first, so no scan opens it meanwhile.
  public func eject(_ id: DeviceID) async {
    await swapFinished(id)
    guard case .held = entries[id]?.holding else { return }
    ejected.insert(id)
    ejecting.insert(id)
    defer { ejecting.remove(id) }
    // Parking can release an MTP handle a scan kept, which resets the unit: requests on the
    // device finish first, as they did when only the close followed them. No new one starts.
    await requestsFinished(id)
    await transport.park(id)
    guard let entry = entries[id], case .held(let session) = entry.holding else { return }
    store(entry.info, .ejected, .unheld, method: entry.method)
    await session.close()
    await kept.removeValue(forKey: id)?.close()
    log.info("device \(id.serial, privacy: .private) ejected")
  }
}
