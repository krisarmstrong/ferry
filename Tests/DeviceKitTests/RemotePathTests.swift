import Foundation
import Testing

@testable import DeviceKit

struct RemotePathTests {
  @Test func parsesAndPrints() throws {
    let path = try RemotePath("/DCIM/Camera")
    #expect(path.components == ["DCIM", "Camera"])
    #expect(path.description == "/DCIM/Camera")
    #expect(path.name == "Camera")
    #expect(path.parent == (try RemotePath("/DCIM")))
  }

  @Test func rootForms() throws {
    #expect(try RemotePath("") == .root)
    #expect(try RemotePath("/") == .root)
    #expect(RemotePath.root.parent == nil)
    #expect(RemotePath.root.name == nil)
    #expect(RemotePath.root.description == "/")
  }

  @Test(arguments: [("/a/../b", ".."), ("/a/./b", "."), ("/a//b", "")])
  func rejectsBadComponents(input: String, offender: String) {
    #expect(throws: TransportError.invalidName(offender)) {
      _ = try RemotePath(input)
    }
  }

  @Test func appendingRejectsSeparators() {
    #expect(throws: TransportError.invalidName("x/y")) {
      _ = try RemotePath.root.appending("x/y")
    }
  }

  @Test func remotePathNormalizesToNFC() throws {
    let decomposed = try RemotePath("/caf\u{0065}\u{0301}")
    let composed = try RemotePath("/caf\u{00E9}")
    #expect(decomposed == composed)
    #expect(decomposed.components == ["caf\u{00E9}"])
  }

  @Test func codableRoundTrip() throws {
    let path = try RemotePath("/DCIM/Camera")
    let item = RemoteItem(
      path: try path.appending("big.mp4"), kind: .file, size: 5_000_000_000,
      modified: Date(timeIntervalSince1970: 1_700_000_000))
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    #expect(try decoder.decode(RemotePath.self, from: encoder.encode(path)) == path)
    #expect(try decoder.decode(RemoteItem.self, from: encoder.encode(item)) == item)
  }
}
