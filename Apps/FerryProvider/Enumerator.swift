import FerryProviderCore
import FileProvider
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Enumerator")

/// Lists a folder, or pages through the working set. Changes come from the agent's change log
/// for the whole domain, whichever container asked: FileProvider applies them by identifier.
final class Enumerator: NSObject, NSFileProviderEnumerator {
  enum Container {
    case workingSet
    case folder(NSFileProviderItemIdentifier)
  }

  private let container: Container
  private let backend: ProviderBackend
  /// The calls still running, cancelled when FileProvider is done with the enumerator (a Finder
  /// window closed), so a listing nobody waits for stops.
  private let running = OSAllocatedUnfairLock(initialState: [UUID: Task<Void, Never>]())

  init(container: Container, backend: ProviderBackend) {
    self.container = container
    self.backend = backend
  }

  func invalidate() {
    let tasks = running.withLock { tasks in
      defer { tasks.removeAll() }
      return Array(tasks.values)
    }
    for task in tasks { task.cancel() }
  }

  /// Runs `body` as a task `invalidate` cancels. The task is registered before it can finish
  /// and remove itself, since it waits on the same lock.
  private func track(_ body: @escaping @Sendable () async -> Void) {
    let token = UUID()
    running.withLock { [running] tasks in
      tasks[token] = Task {
        await body()
        running.withLock { _ = $0.removeValue(forKey: token) }
      }
    }
  }

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Handoff(observer)
    let backend = backend
    switch container {
    case .workingSet:
      track {
        do {
          let result = try await backend.workingSet(from: page)
          observer.value.didEnumerate(result.items)
          observer.value.finishEnumerating(upTo: result.next)
        } catch {
          observer.value.finishEnumeratingWithError(ErrorMapping.forFileProvider(error))
        }
      }
    case .folder(let folder):
      track {
        do {
          let result = try await backend.children(of: folder, from: page)
          observer.value.didEnumerate(result.items)
          observer.value.finishEnumerating(upTo: result.next)
        } catch {
          observer.value.finishEnumeratingWithError(ErrorMapping.forFileProvider(error))
        }
      }
    }
  }

  func enumerateChanges(
    for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor
  ) {
    let observer = Handoff(observer)
    let backend = backend
    track {
      do {
        let changes = try await backend.changes(since: anchor)
        observer.value.didUpdate(changes.updated)
        observer.value.didDeleteItems(withIdentifiers: changes.deleted)
        observer.value.finishEnumeratingChanges(upTo: changes.anchor, moreComing: false)
      } catch {
        observer.value.finishEnumeratingWithError(ErrorMapping.forFileProvider(error))
      }
    }
  }

  func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
    let completion = Handoff(completionHandler)
    let backend = backend
    Task {
      do {
        completion.value(try await backend.currentAnchor())
      } catch {
        // No anchor makes FileProvider enumerate again once the agent answers.
        log.error("no sync anchor: \(error, privacy: .public)")
        completion.value(nil)
      }
    }
  }
}
