import CLibMTP
import DeviceKit

extension TransportError {
  /// Drains `device`'s libmtp error stack into one error and clears the stack.
  ///
  /// A lost USB link surfaces as `.deviceDisconnected`; everything else becomes `.io` carrying
  /// libmtp's own messages, since MTP response codes do not distinguish causes reliably.
  static func drained(
    from device: UnsafeMutablePointer<LIBMTP_mtpdevice_t>, during operation: String
  ) -> TransportError {
    defer { LIBMTP_Clear_Errorstack(device) }
    var messages: [String] = []
    var disconnected = false
    var cancelled = false
    var node = LIBMTP_Get_Errorstack(device)
    while let error = node {
      switch error.pointee.errornumber {
      case LIBMTP_ERROR_NO_DEVICE_ATTACHED, LIBMTP_ERROR_USB_LAYER:
        disconnected = true
      case LIBMTP_ERROR_CANCELLED:
        cancelled = true
      default:
        break
      }
      if let text = error.pointee.error_text {
        messages.append(String(cString: text))
      }
      node = error.pointee.next
    }
    if disconnected { return .deviceDisconnected }
    if cancelled { return .cancelled }
    guard !messages.isEmpty else { return .io("\(operation) failed") }
    return .io("\(operation) failed: \(messages.joined(separator: "; "))")
  }
}
