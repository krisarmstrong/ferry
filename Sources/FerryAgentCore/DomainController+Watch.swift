import DeviceKit

/// What the change watch asks of the controller.
extension DomainController {
  /// The storage of `domain`, while it is connected.
  func connectedStorage(of domain: String) -> StorageID? {
    guard let entry = domains[domain], entry.connected else { return nil }
    return entry.storage
  }

  /// The devices with a connected domain.
  func connectedDevices() -> Set<DeviceID> {
    Set(domains.values.filter(\.connected).compactMap { $0.storage?.device })
  }

  /// The folders the domain's table knows clients listed, parents first; none while it is not
  /// connected.
  func knownFolders(of domain: String) async -> [RemotePath] {
    do throws(TransportError) {
      return try await items(of: domain).knownFolders()
    } catch {
      return []
    }
  }

  /// Lists `folders` of the domain again and signals it if a listing differed. Failures are
  /// left to the next pass.
  func relistAndSignal(_ folders: [RemotePath], in identifier: String) async {
    let (changed, _) = await relistFolders(folders, of: identifier)
    if changed { await signal(identifier) }
  }

  /// Whether the domain's table still knows `folder`: a folder found gone is not watched.
  func knows(_ folder: RemotePath, in domain: String) async -> Bool {
    do throws(TransportError) {
      return try await items(of: domain).knows(folder)
    } catch {
      return false
    }
  }
}
