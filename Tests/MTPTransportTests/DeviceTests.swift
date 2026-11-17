import Foundation
import Testing

/// Parent of every suite that talks to a real device. Only one process session can hold the
/// device, so all of them run one at a time, and only when `FERRY_DEVICE_TESTS=1`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["FERRY_DEVICE_TESTS"] == "1"), .serialized)
enum DeviceTests {}
