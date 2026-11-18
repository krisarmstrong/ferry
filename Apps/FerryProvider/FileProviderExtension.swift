import FerryIPC
import FerryProviderCore
import FileProvider
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Extension")

/// The FileProvider extension for one domain. Every call goes to `ProviderBackend`, which
/// forwards it to the agent; this class only snapshots FileProvider's arguments and completes
/// its callbacks.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
  private let backend: ProviderBackend
  private let manager: NSFileProviderManager?

  required init(domain: NSFileProviderDomain) {
    manager = NSFileProviderManager(for: domain)
    // The build records the signing team in Info.plist; `make app` checks it is there.
    guard let identity = FerryIdentity() else {
      preconditionFailure("FerryTeamID is missing from the extension's Info.plist")
    }
    backend = ProviderBackend(
      domain: domain.identifier.rawValue, client: AgentClient(identity: identity))
    super.init()
  }

  func invalidate() {}

  func item(
    for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
    completionHandler: @escaping (NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let backend = backend
    return answer(
      { try await backend.item(identifier) },
      then: { result in
        switch result {
        case .success(let item): completionHandler(item, nil)
        case .failure(let error): completionHandler(nil, error)
        }
      })
  }

  func fetchContents(
    for itemIdentifier: NSFileProviderItemIdentifier,
    version requestedVersion: NSFileProviderItemVersion?, request: NSFileProviderRequest,
    completionHandler: @escaping (URL?, NSFileProviderItem?, (any Error)?) -> Void
  ) -> Progress {
    let backend = backend
    let directory = temporaryDirectory()
    let (progress, update) = FileProgress.make(.downloading)
    return answer(
      progress: progress,
      { try await backend.fetch(itemIdentifier, into: directory, progress: update) },
      then: { result in
        switch result {
        case .success(let (url, item)): completionHandler(url, item, nil)
        case .failure(let error): completionHandler(nil, nil, error)
        }
      })
  }

  func createItem(
    basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?)
      -> Void
  ) -> Progress {
    let template: ItemTemplate
    do {
      template = try ItemTemplate(itemTemplate)
    } catch {
      completionHandler(nil, [], false, error)
      return Progress()
    }
    let backend = backend
    let (progress, update) = FileProgress.make(.uploading)
    return answer(
      progress: progress,
      { try await backend.create(template, contents: url, progress: update) },
      then: { result in
        switch result {
        case .success(let item): completionHandler(item, [], false, nil)
        case .failure(let error): completionHandler(nil, [], false, error)
        }
      })
  }

  // FileProvider's protocol requirement fixes this signature.
  // swiftlint:disable:next function_parameter_count
  func modifyItem(
    _ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion,
    changedFields: NSFileProviderItemFields, contents newContents: URL?,
    options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
    completionHandler:
      @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, (any Error)?)
      -> Void
  ) -> Progress {
    let identifier = item.itemIdentifier
    let changes = ItemChanges(changedFields)
    let base = ContentVersion(base: version)
    let onConflict: ConflictPolicy = options.contains(.failOnConflict) ? .fail : .keepBoth
    let template: ItemTemplate
    do {
      template = try ItemTemplate(item)
    } catch {
      completionHandler(nil, [], false, error)
      return Progress()
    }
    let backend = backend
    let (progress, update) = FileProgress.make(.uploading)
    return answer(
      progress: progress,
      {
        try await backend.modify(
          identifier, to: template, changed: changes, contents: newContents, base: base,
          onConflict: onConflict, progress: update)
      },
      then: { result in
        switch result {
        case .success(let item): completionHandler(item, [], false, nil)
        case .failure(let error): completionHandler(nil, [], false, error)
        }
      })
  }

  func deleteItem(
    identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
    completionHandler: @escaping ((any Error)?) -> Void
  ) -> Progress {
    let backend = backend
    let base = ContentVersion(base: version)
    let recursive = options.contains(.recursive)
    return answer(
      { try await backend.delete(identifier, base: base, recursive: recursive) },
      then: { result in
        switch result {
        case .success: completionHandler(nil)
        case .failure(let error): completionHandler(error)
        }
      })
  }

  /// The domain's temporary directory, on the same volume as its files so FileProvider can move
  /// a download into place; the sandbox's own when the domain has none.
  private func temporaryDirectory() -> URL {
    do {
      if let url = try manager?.temporaryDirectoryURL() { return url }
    } catch {
      log.error("no temporary directory for the domain: \(error, privacy: .public)")
    }
    return URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
  }

  func enumerator(
    for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest
  ) throws -> NSFileProviderEnumerator {
    if containerItemIdentifier == .workingSet {
      return Enumerator(container: .workingSet, backend: backend)
    }
    if containerItemIdentifier == .trashContainer {
      return EmptyTrashEnumerator()
    }
    // Anything else the agent did not assign.
    guard ItemID(containerItemIdentifier) != nil else { throw NSFileProviderError(.noSuchItem) }
    return Enumerator(container: .folder(containerItemIdentifier), backend: backend)
  }
}

/// Runs `work` in a task and hands its result to `complete` exactly once: the task is its only
/// caller. Cancelling the returned progress cancels the task, and `ProviderBackend` then returns
/// promptly with `.userCancelled`. A transfer passes the byte-counting `progress` its work
/// feeds; anything else gets one unit, done when the work is.
private func answer<T: Sendable>(
  progress: Progress = Progress(totalUnitCount: 1),
  _ work: @escaping @Sendable () async throws -> T,
  then complete: @escaping (Result<T, any Error>) -> Void
) -> Progress {
  let complete = Handoff(complete)
  let task = Task {
    let result: Result<T, any Error>
    do {
      let value = try await work()
      result = .success(value)
    } catch {
      result = .failure(error)
    }
    progress.completedUnitCount = progress.totalUnitCount
    complete.value(result)
  }
  progress.cancellationHandler = { task.cancel() }
  return progress
}

/// Carries one of FileProvider's callbacks or observers, which are not `Sendable`, into the task
/// that answers it. Each is used by that one task only, and FileProvider accepts calls to them
/// from any thread.
struct Handoff<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}
