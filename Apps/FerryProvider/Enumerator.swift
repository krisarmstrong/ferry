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

  init(container: Container, backend: ProviderBackend) {
    self.container = container
    self.backend = backend
  }

  func invalidate() {}

  func enumerateItems(
    for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage
  ) {
    let observer = Handoff(observer)
    let backend = backend
    switch container {
    case .workingSet:
      Task {
        do {
          let result = try await backend.workingSet(from: page)
          observer.value.didEnumerate(result.items)
          observer.value.finishEnumerating(upTo: result.next)
        } catch {
          observer.value.finishEnumeratingWithError(ErrorMapping.forFileProvider(error))
        }
      }
    case .folder(let folder):
      Task {
        do {
          observer.value.didEnumerate(try await backend.children(of: folder))
          observer.value.finishEnumerating(upTo: nil)
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
    Task {
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
        log.error("no sync anchor: \(error, privacy: .private)")
        completion.value(nil)
      }
    }
  }
}
