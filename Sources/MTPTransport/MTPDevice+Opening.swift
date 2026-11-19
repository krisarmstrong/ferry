import CLibMTP
import DeviceKit
import Dispatch
import Foundation

/// A device for libmtp to open, built by `MTPDeviceTable` from the IOKit registry.
///
/// `@unchecked`: the struct's only pointers are the vendor and product strings, which point into
/// libmtp's static device table and are never written or freed.
struct RawDeviceRef: @unchecked Sendable {
  let raw: LIBMTP_raw_device_t
}

/// A handle just opened, on its way from `DeviceOpener` to the `MTPDevice` that owns it.
///
/// `@unchecked`: the handle is used only on the device's queue, before and after the hand-off,
/// and nothing else keeps it.
struct OpenedHandle: @unchecked Sendable {
  let handle: UnsafeMutablePointer<LIBMTP_mtpdevice_t>
  let info: DeviceInfo
}

/// Runs the open on a device's queue before the `MTPDevice` that will own the handle exists.
actor DeviceOpener {
  private let queue: DispatchSerialQueue

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    queue.asUnownedSerialExecutor()
  }

  init(queue: DispatchSerialQueue) {
    self.queue = queue
  }

  func open(_ raw: RawDeviceRef) -> OpenedHandle? {
    Self.openNow(raw)
  }

  /// Opens `raw` on the calling thread, which must be the device's queue.
  nonisolated static func openNow(_ raw: RawDeviceRef) -> OpenedHandle? {
    _ = MTPDevice.libraryInitialized
    var raw = raw.raw
    guard let handle = LIBMTP_Open_Raw_Device_Uncached(&raw) else { return nil }
    return OpenedHandle(handle: handle, info: MTPDevice.identify(handle, raw: raw))
  }
}

extension MTPEntry {
  init(_ file: LIBMTP_file_t) {
    self.init(
      objectID: file.item_id,
      parent: file.parent_id,
      name: file.filename.map { String(cString: $0) } ?? "",
      isFolder: file.filetype == LIBMTP_FILETYPE_FOLDER,
      size: file.filesize,
      modified: Date(timeIntervalSince1970: TimeInterval(file.modificationdate)))
  }
}
