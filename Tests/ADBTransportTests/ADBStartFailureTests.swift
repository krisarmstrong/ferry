import Foundation
import Testing
import os

@testable import ADBTransport

struct ADBStartFailureTests {
  /// A missing adb is a state the menu already shows; any other failure is a real problem.
  @Test(arguments: [
    (ADBError.adbNotInstalled, OSLogType.info), (.serverUnavailable, .error),
    (.failed("adb start-server exited 1"), .error),
  ])
  func onlyAMissingAdbIsQuiet(error: ADBError, level: OSLogType) {
    #expect(ADBTransport.startFailureLevel(error) == level)
  }
}
