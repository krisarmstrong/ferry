import DeviceKit
import Foundation
import Testing

@testable import FerryIPC

/// MTP and ADB both date files to the second, from different clocks' representations: a
/// version matches another of the same size whose date falls in the same second.
struct ContentVersionTests {
  func version(_ size: UInt64, _ seconds: TimeInterval) -> ContentVersion {
    ContentVersion(
      RemoteItem(
        path: .root, kind: .file, size: size, modified: Date(timeIntervalSince1970: seconds)))
  }

  @Test func versionsMatchToTheSecond() {
    #expect(version(3, 1_700_000_000).matches(version(3, 1_700_000_000.75)))
    #expect(!version(3, 1_700_000_000).matches(version(3, 1_700_000_001)))
    #expect(!version(3, 1_700_000_000).matches(version(4, 1_700_000_000)))
  }
}
