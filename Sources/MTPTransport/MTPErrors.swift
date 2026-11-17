import CLibMTP
import DeviceKit

/// Swift mirror of `LIBMTP_error_number_t`, so classification is testable without C.
enum MTPErrorCode: Sendable, Equatable {
  case general
  case ptpLayer
  case usbLayer
  case memoryAllocation
  case noDevice
  case storageFull
  case connecting
  case cancelled
  case other(UInt32)

  init(_ code: LIBMTP_error_number_t) {
    switch code {
    case LIBMTP_ERROR_GENERAL: self = .general
    case LIBMTP_ERROR_PTP_LAYER: self = .ptpLayer
    case LIBMTP_ERROR_USB_LAYER: self = .usbLayer
    case LIBMTP_ERROR_MEMORY_ALLOCATION: self = .memoryAllocation
    case LIBMTP_ERROR_NO_DEVICE_ATTACHED: self = .noDevice
    case LIBMTP_ERROR_STORAGE_FULL: self = .storageFull
    case LIBMTP_ERROR_CONNECTING: self = .connecting
    case LIBMTP_ERROR_CANCELLED: self = .cancelled
    default: self = .other(code.rawValue)
    }
  }
}

/// One entry from a device's libmtp error stack.
struct MTPErrorEntry: Sendable, Equatable {
  let code: MTPErrorCode
  let text: String
}

extension TransportError {
  /// Classifies a drained libmtp error stack. Precedence: a cancel, then a lost device, then
  /// (when reading storages) a lock, then `.io` carrying libmtp's messages.
  ///
  /// libmtp reports a USB link lost mid-operation as a PTP- or USB-layer error, which a
  /// protocol failure on a healthy link also produces; `deviceStillPresent` tells them apart
  /// and is only consulted for those codes.
  ///
  /// With `generalMeansLocked`, a stack holding only general errors (or none) is a locked
  /// device: that is how libmtp reports a phone that exposes no storages.
  static func classify(
    _ entries: [MTPErrorEntry], during operation: String, generalMeansLocked: Bool = false,
    deviceStillPresent: () -> Bool
  ) -> TransportError {
    let codes = entries.map(\.code)
    if codes.contains(.cancelled) { return .cancelled }
    if codes.contains(.noDevice) { return .deviceDisconnected }
    if codes.contains(where: { $0 == .usbLayer || $0 == .ptpLayer }), !deviceStillPresent() {
      return .deviceDisconnected
    }
    if generalMeansLocked, codes.allSatisfy({ $0 == .general }) { return .deviceLocked }
    let messages = entries.map(\.text).filter { !$0.isEmpty }
    guard !messages.isEmpty else { return .io("\(operation) failed") }
    return .io("\(operation) failed: \(messages.joined(separator: "; "))")
  }
}

/// Reads `device`'s libmtp error stack and clears it.
func drainErrorStack(_ device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>) -> [MTPErrorEntry] {
  defer { LIBMTP_Clear_Errorstack(device) }
  var entries: [MTPErrorEntry] = []
  var node = LIBMTP_Get_Errorstack(device)
  while let error = node {
    let text = error.pointee.error_text.map { String(cString: $0) } ?? ""
    entries.append(MTPErrorEntry(code: MTPErrorCode(error.pointee.errornumber), text: text))
    node = error.pointee.next
  }
  return entries
}
