import FileProvider
import Foundation

extension SystemServices {
  /// As the agent removes them (`FileProviderDomains.removeAll`): every domain is tried, with
  /// `.preserveDirtyUserData`, then the first failure is thrown.
  public func removeFileProviderDomains() async throws -> [URL] {
    var preserved: [URL] = []
    var failure: (any Error)?
    for domain in try await NSFileProviderManager.domains() {
      do {
        let location = try await NSFileProviderManager.remove(
          domain, mode: .preserveDirtyUserData)
        preserved += location.map { [$0] } ?? []
      } catch {
        Self.log.error("removing a domain failed: \(error, privacy: .private)")
        failure = failure ?? error
      }
    }
    if let failure { throw failure }
    return preserved
  }
}
