import FerryIPC
import Foundation

/// The system's FileProvider domains. The agent's implementation wraps `NSFileProviderManager`.
public protocol DomainManaging: Sendable {
  /// Adds the domain, or renames it if one with the same identifier exists.
  func add(_ spec: DomainSpec) async throws
  func disconnect(_ identifier: String) async throws
  func reconnect(_ identifier: String) async throws
  /// Hides the domain from Finder, or shows it again. The domain, its files and its unsent
  /// changes stay: only whether Finder lists it changes.
  func setHidden(_ identifier: String, hidden: Bool) async throws
  /// The identifiers of the Ferry domains the system hides from Finder now.
  func hiddenDomains() async throws -> Set<String>
  /// Whether the domain's pending set holds changes not yet sent to its device. Answers in
  /// bounded time, `false` when the system cannot say.
  func hasUnsentChanges(_ identifier: String) async -> Bool
  /// Removes the domain, keeping changes not yet sent to the device, and returns where they were
  /// saved, if there were any.
  func remove(_ identifier: String) async throws -> URL?
  /// Removes every Ferry domain the same way, and returns where unsent changes were saved.
  func removeAll() async throws -> [URL]
  /// Tells the system the domain's working set changed. A replicated FileProvider extension
  /// ignores signals for any other container; it then asks the agent for `.changes`.
  func signal(_ identifier: String) async
  /// Tells the system that requests it was told need the device unlocked
  /// (`NSFileProviderError.notAuthenticated`) can run again: until then it holds them, however
  /// long the device has been unlocked.
  func lockResolved(_ identifier: String) async
  /// Whether the user has enabled Ferry's domains, or none exists yet. New domains start disabled
  /// and only the user can enable them, so `.disabled` is a normal state.
  func providerState() async -> ProviderState
  /// The identifiers of the Ferry domains the system has, including ones from before this
  /// process started.
  func existing() async throws -> [String]
  /// The name the system shows for a domain, if it has the domain.
  func displayName(of identifier: String) async -> String?
}

extension DomainManaging {
  public func displayName(of identifier: String) async -> String? { nil }
}
