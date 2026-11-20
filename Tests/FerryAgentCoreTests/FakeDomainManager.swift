import FerryIPC
import Foundation

@testable import FerryAgentCore

/// Records every call, so a test can wait for the controller to act on a hub event.
actor FakeDomainManager: DomainManaging {
  enum Call: Equatable, Sendable {
    case add(DomainSpec)
    case disconnect(String)
    case reconnect(String)
    case remove(String)
    case removeAll
    case signal(String)
  }

  private(set) var calls: [Call] = []
  private let preexisting: [String]
  /// Set by `holdExisting()`: `existing()` waits until `releaseExisting()`.
  private var existingHeld = false
  private var existingWaiter: CheckedContinuation<Void, Never>?
  private var provider = ProviderState.disabled
  /// Where removing each domain saves its unsent changes.
  private var preserved: [String: URL] = [:]
  private var waiters: [Int: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
  private var nextWaiter = 0

  /// `existing` are the domains the system already has, as after an agent restart.
  /// How many listings of the system's domains fail before one succeeds.
  private var listingFailures: Int

  /// How many removals fail before one succeeds.
  private var removalFailures: Int

  /// The domains the system has now: those it had at start, plus each one added, less each one
  /// removed. Hiding changes nothing here: the system keeps a hidden domain and its files.
  private(set) var registered: Set<String>
  /// The registered domains Finder does not show.
  private(set) var hidden: Set<String> = []
  /// How many hide or show requests fail before one succeeds.
  private var visibilityFailures = 0
  /// How many listings of the hidden domains fail before one succeeds.
  private var hiddenListingFailures = 0
  private var hiddenWaiters:
    [Int: (hidden: Set<String>, continuation: CheckedContinuation<Void, Never>)] = [:]

  init(existing: [String] = [], listingFailures: Int = 0, removalFailures: Int = 0) {
    preexisting = existing
    self.listingFailures = listingFailures
    self.removalFailures = removalFailures
    registered = Set(existing)
  }

  /// The domain is shown: `DomainManaging.add` adds a shown domain, and an add for an existing
  /// identifier sets its hidden state too (`NSFileProviderManager.h`, `addDomain:`).
  func add(_ spec: DomainSpec) async throws {
    registered.insert(spec.identifier)
    hidden.remove(spec.identifier)
    record(.add(spec))
  }
  func disconnect(_ identifier: String) async throws { record(.disconnect(identifier)) }
  func reconnect(_ identifier: String) async throws { record(.reconnect(identifier)) }
  func remove(_ identifier: String) async throws -> URL? {
    record(.remove(identifier))
    if removalFailures > 0 {
      removalFailures -= 1
      throw CocoaError(.featureUnsupported)
    }
    registered.remove(identifier)
    hidden.remove(identifier)
    return preserved[identifier]
  }
  func removeAll() async throws -> [URL] {
    record(.removeAll)
    registered = []
    hidden = []
    return preserved.keys.sorted().compactMap { preserved[$0] }
  }
  func signal(_ identifier: String) async {
    record(.signal(identifier))
  }
  /// Kept out of `calls`: every disconnect and reconnect comes with one, so tests of the order
  /// of system calls read the same either way. Tests check `hidden` instead.
  func setHidden(_ identifier: String, hidden isHidden: Bool) async throws {
    guard registered.contains(identifier) else { throw CocoaError(.fileNoSuchFile) }
    if visibilityFailures > 0 {
      visibilityFailures -= 1
      throw CocoaError(.featureUnsupported)
    }
    if isHidden {
      hidden.insert(identifier)
    } else {
      hidden.remove(identifier)
    }
    for (id, waiter) in hiddenWaiters where waiter.hidden == hidden {
      hiddenWaiters.removeValue(forKey: id)?.continuation.resume()
    }
  }

  /// Returns the hidden domains once they are exactly `expected` or the test is cancelled, as
  /// its time limit does: a hide or show comes from a reconcile no call marks the end of.
  func waitUntilHidden(_ expected: Set<String>) async -> Set<String> {
    guard hidden != expected, !Task.isCancelled else { return hidden }
    nextWaiter += 1
    let id = nextWaiter
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled {
          continuation.resume()
        } else {
          hiddenWaiters[id] = (expected, continuation)
        }
      }
    } onCancel: {
      Task { await self.releaseHiddenWaiter(id) }
    }
    return hidden
  }

  private func releaseHiddenWaiter(_ id: Int) {
    hiddenWaiters.removeValue(forKey: id)?.continuation.resume()
  }

  /// The next `count` hide or show requests fail.
  func failVisibility(_ count: Int) {
    visibilityFailures = count
  }

  func hiddenDomains() async throws -> Set<String> {
    if hiddenListingFailures > 0 {
      hiddenListingFailures -= 1
      throw CocoaError(.featureUnsupported)
    }
    return hidden
  }

  /// The next `count` listings of the hidden domains fail.
  func failHiddenListing(_ count: Int) {
    hiddenListingFailures = count
  }

  /// The system hides or shows the domain without Ferry asking, so Ferry's idea of it is stale.
  func drift(_ identifier: String, hidden isHidden: Bool) {
    if isHidden {
      hidden.insert(identifier)
    } else {
      hidden.remove(identifier)
    }
  }

  /// The registered domains Finder shows.
  var visible: Set<String> { registered.subtracting(hidden) }

  func providerState() async -> ProviderState { provider }
  func existing() async throws -> [String] {
    if existingHeld {
      await withCheckedContinuation { existingWaiter = $0 }
    }
    if listingFailures > 0 {
      listingFailures -= 1
      throw CocoaError(.featureUnsupported)
    }
    return preexisting
  }

  /// Makes `existing()` wait, as listing the system's domains can take a while after a restart.
  func holdExisting() {
    existingHeld = true
  }

  func releaseExisting() {
    existingHeld = false
    existingWaiter?.resume()
    existingWaiter = nil
  }

  func setProvider(_ state: ProviderState) {
    provider = state
  }

  /// Removing `identifier` saves unsent changes to `location`.
  func preserve(_ identifier: String, at location: URL) {
    preserved[identifier] = location
  }

  /// Returns every call so far, once there are at least `count` or the test is cancelled, as
  /// its time limit does, so a missing call fails the test instead of hanging it.
  func waitForCalls(_ count: Int) async -> [Call] {
    guard calls.count < count, !Task.isCancelled else { return calls }
    nextWaiter += 1
    let id = nextWaiter
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        // Cancelled before registering: the handler's release has nothing to resume.
        if Task.isCancelled {
          continuation.resume()
        } else {
          waiters[id] = (count, continuation)
        }
      }
    } onCancel: {
      Task { await self.release(id) }
    }
    return calls
  }

  private func release(_ id: Int) {
    waiters.removeValue(forKey: id)?.continuation.resume()
  }

  private func record(_ call: Call) {
    calls.append(call)
    for (id, waiter) in waiters where waiter.count <= calls.count {
      release(id)
    }
  }
}
