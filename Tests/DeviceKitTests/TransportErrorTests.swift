import DeviceKit
import Testing
import os

/// A cancel is the user's own doing, not a fault: it is logged as information.
@Test func cancelledIsLoggedAsInformation() {
  #expect(TransportError.cancelled.logType == .info)
  #expect(TransportError.deviceDisconnected.logType == .error)
}
