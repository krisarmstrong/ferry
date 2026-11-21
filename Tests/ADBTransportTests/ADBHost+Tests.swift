import Foundation

@testable import ADBTransport

extension ADBHost {
  /// A host for a fake server: it starts no server of its own.
  init(port: UInt16, locator: ADBLocator) {
    self.init(port: port, locator: locator, launcher: { _ in }, backoff: Backoff())
  }
}
