import DeviceKit
import FerryIPC
import Foundation
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "AgentService")

/// Serves requests from the app and the FileProvider extension against the hub's sessions.
///
/// Requests come from sandboxed processes, so the agent trusts nothing they name. An item is
/// named by an `ItemID` the agent assigned, and resolved through the domain's `ItemTable`; a new
/// name must be one path component. File contents arrive as an open descriptor, never a path: the
/// agent copies between that descriptor and a scratch file of its own (see `FileTransfer`), so
/// it never opens a file a client chose. Uploads go through the domain's one `SafeWriter`.
///
/// Every new, changed or vanished item the agent sees, whether from a request that changed the
/// device or a listing that found the device changed, is recorded in the domain's change log and
/// the domain's working set is signalled, so Finder learns of changes made outside it.
///
/// Every operation that resolves an identifier runs through the domain's gate, from the lookup to
/// the table update after the device changed, so a listing can never see the device and the table
/// disagree and drop an item that is only being renamed. The device runs one operation at a time
/// anyway; the copies to and from the client's descriptor stay outside the gate.
///
/// A transfer stops at its next block once its client cancels it or goes away (see
/// `RequestCancellation`); any other request finishes, and its reply is then dropped.
public actor AgentService: AgentHandling {
  let hub: DeviceHub
  let domains: DomainController
  let transfers: TransferBoard
  /// Where the agent keeps its scratch copies of clients' files (see `FileTransfer`).
  let scratchFolder: URL
  /// adb over the network; `nil` where adb is not used.
  let wireless: WirelessADB?
  /// APK install, screenshot and screen recording; `nil` where adb is not used.
  let tools: ADBTools?
  /// Whether the USB notifications are armed; `nil` where nothing watches USB.
  let usbWatch: USBWatchState?
  /// Follows the folders clients list for changes made on the device; `nil` where nothing does.
  let changes: ChangeWatch?

  public init(
    hub: DeviceHub, domains: DomainController,
    scratch: URL = FileManager.default.temporaryDirectory, wireless: WirelessADB? = nil,
    tools: ADBTools? = nil, usbWatch: USBWatchState? = nil,
    transfers: TransferBoard = TransferBoard(), changes: ChangeWatch? = nil
  ) {
    self.transfers = transfers
    self.usbWatch = usbWatch
    self.changes = changes
    self.hub = hub
    self.domains = domains
    scratchFolder = scratch
    self.wireless = wireless
    self.tools = tools
  }

  public func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse {
    await handle(request, file: file, progress: progress, logs: nil)
  }

  public func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler,
    logs: LogSink?
  ) async -> AgentResponse {
    do throws(TransportError) {
      guard Self.takesFile(request) == (file != nil) else {
        throw .io(String(localized: AgentText.badRequest))
      }
      // A request on a Finder location starts when its session operation holds the device
      // (`DeviceTurns`); the rest start now.
      if !Self.waitsForTheDevice(request) { RequestCancellation.current?.markStarted() }
      return try await perform(request, file: file?.fileDescriptor, progress: progress, logs: logs)
    } catch {
      log.log(
        level: error.logType,
        "request failed: \(String(describing: error), privacy: .private)")
      return .failure(error)
    }
  }

  /// `file` is present exactly when `takesFile(request)`.
  private func perform(
    _ request: AgentRequest, file: Int32?, progress: @escaping TransferProgressHandler,
    logs: LogSink?
  ) async throws(TransportError) -> AgentResponse {
    if let response = try await performAppRequest(request) { return response }
    let tool = try await performToolRequest(request, file: file, progress: progress, logs: logs)
    if let tool { return tool }
    switch (request, file) {
    case (.item(let domain, let id), _):
      return .entry(try await item(id, in: domain))
    case (.list(let domain, let folder), _):
      return .entries(try await list(folder, in: domain))
    case (.fetch(let domain, let id), let file?):
      return .entry(try await fetch(id, in: domain, into: file, progress: progress))
    case (.create(let domain, let parent, let name, _), let file?):
      return .entry(try await upload(file, as: name, in: parent, of: domain, progress: progress))
    case (.create(let domain, let parent, let name, _), nil):
      return .entry(try await makeFolder(name, in: parent, of: domain))
    case (.replaceContents(let domain, let id, let base, let onConflict), let file?):
      return try await replace(
        Replacement(id: id, base: base, onConflict: onConflict), with: file, in: domain,
        progress: progress)
    case (.rename(let domain, let id, let name), _):
      return .entry(try await rename(id, to: name, in: domain))
    case (.move(let domain, let id, let folder), _):
      return .entry(try await move(id, to: folder, in: domain))
    case (.delete(let domain, let id, let base, let recursive), _):
      try await delete(id, base: base, recursive: recursive, in: domain)
      return .done
    case (.changes(let domain, let since), _):
      let changes = try await domains.items(of: domain).changes(since: since)
      return .changes(
        anchor: changes.anchor, updated: changes.updated, deleted: changes.deleted,
        expired: changes.expired)
    case (.workingSet(let domain, let page), _):
      return try await workingSet(page, in: domain)
    case (.devices, _):
      return .devices(await finderDevices())
    case (.sendFile(let id, let name), let file?):
      return .entry(try await send(file, as: name, to: id, progress: progress))
    case (.fetch, nil), (.replaceContents, nil), (.status, _), (.recheck, _), (.recheckADB, _),
      (.refresh, _), (.eject, _), (.removeAllDomains, _), (.connectAddress, _), (.pair, _),
      (.connectWireless, _), (.enableWireless, _), (.forgetWireless, _), (.confirmWireless, _),
      (.ignoreWireless, _), (.installAPK, _), (.screenshot, _), (.startRecording, _),
      (.stopRecording, _), (.saveRecording, _), (.discardRecording, _), (.startLogcat, _),
      (.stopLogcat, _), (.forwards, _), (.addForward, _), (.removeForward, _), (.deviceInfo, _),
      (.shellTarget, _), (.sendFile, nil):
      throw .io(String(localized: AgentText.badRequest))
    }
  }

  /// Answers the app's requests, which name devices rather than items; `nil` for any other.
  private func performAppRequest(_ request: AgentRequest) async throws(TransportError)
    -> AgentResponse?
  {
    switch request {
    case .status:
      return .status(await status())
    case .recheck(let id):
      await hub.recheck(id)
      return .done
    case .recheckADB:
      await hub.recheckADB()
      return .done
    case .refresh(let id):
      try await domains.refresh(id)
      return .done
    case .eject(let id):
      return .removed(preserved: await domains.eject(id))
    case .removeAllDomains:
      // Remove Ferry forgets the devices it reconnects over the network too.
      await wireless?.forgetAll()
      return .removed(preserved: try await domains.removeAll())
    default:
      return await performWirelessRequest(request)
    }
  }

  // MARK: Reading

  /// The item as the device has it now. If the device now has another kind of item at its path,
  /// the item Finder asked about is gone.
  private func item(_ id: ItemID, in domain: String) async throws(TransportError)
    -> ProviderEntry
  {
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: id)
      let entry = await route.items.observed(
        try await route.session.item(at: path, in: route.storage))
      guard entry.id == id else { throw .unknownItem }
      return entry
    }
  }

  private func list(_ folder: ItemID, in domain: String) async throws(TransportError)
    -> [ProviderEntry]
  {
    let (path, entries) = try await gated(domain) { route throws(TransportError) in
      let path = try await route.path(of: folder)
      let items = try await route.writer.visibleList(path, in: route.storage)
      return (path, await route.items.listed(path, children: items))
    }
    // Outside the gate: the watch reads the domain's table.
    await changes?.listed(path, in: domain)
    return entries
  }

  /// One page of the working set. The page token is the last identifier served, as UTF-8.
  private func workingSet(_ page: Data?, in domain: String) async throws(TransportError)
    -> AgentResponse
  {
    let cursor = try page.map { data throws(TransportError) in
      guard let id = String(data: data, encoding: .utf8).flatMap(ItemID.init(rawValue:)) else {
        throw .io(String(localized: AgentText.badRequest))
      }
      return id
    }
    let (entries, next) = try await gated(domain) { route in
      await route.items.workingSet(after: cursor, size: Self.workingSetPageSize)
    }
    return .page(entries: entries, next: next.map { Data($0.rawValue.utf8) })
  }

  // MARK: Changing

  private func makeFolder(_ name: String, in parent: ItemID, of domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let name = try Self.creatable(name)
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.writableFolder(parent).appending(name)
      return await route.items.created(try await route.session.makeFolder(path, in: route.storage))
    }
  }

  private func rename(_ id: ItemID, to name: String, in domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    let validated = try Self.creatable(name)
    return try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      let item = try await route.session.rename(path, to: validated, in: route.storage)
      await route.items.moved(path, to: item.path)
      return await route.items.changed(item, id: id)
    }
  }

  private func move(_ id: ItemID, to folder: ItemID, in domain: String)
    async throws(TransportError) -> ProviderEntry
  {
    try await gated(domain) { route throws(TransportError) in
      let path = try await route.changeable(id)
      let destination = try await route.writableFolder(folder)
      let item = try await route.session.move(path, toFolder: destination, in: route.storage)
      await route.items.moved(path, to: item.path)
      return await route.items.changed(item, id: id)
    }
  }

  /// Deletes the item as the device has it now. A file the device changed since `base` is kept
  /// and its new state recorded, so FileProvider puts it back. A folder is deleted with its
  /// contents only if `recursive`, and only if FileProvider has seen all of them (see
  /// `requireSeen`): without it, one that holds anything Finder would show is kept, since Finder
  /// may have last seen it empty. An item already gone, from the table or from the device, is
  /// deleted already: FileProvider expects success.
  private func delete(
    _ id: ItemID, base: ContentVersion?, recursive: Bool, in domain: String
  ) async throws(TransportError) {
    try await gated(domain) { route throws(TransportError) in
      guard id != .root else { throw .unsupported("changing the storage root") }
      guard let path = await route.items.path(for: id) else { return }
      let current: RemoteItem
      do throws(TransportError) {
        current = try await route.session.item(at: path, in: route.storage)
      } catch .notFound {
        await route.items.removed(path)
        return
      }
      if path.isInPackageFolder(isFolder: current.kind == .folder) { throw .readOnly(path) }
      // Everything the delete was checked against: the device deletes only those.
      var checked = [current]
      switch current.kind {
      case .file:
        // Compared as FileProvider holds it: at the size a download delivered, if the device
        // still lists the file with the stale size it had then.
        if let base, !ContentVersion(await route.items.observed(current).item).matches(base) {
          throw .changedOnDevice(path)
        }
      case .folder:
        // The listing that checks also reaps partials abandoned in the folder, which Finder
        // never shows.
        if recursive {
          checked += try await Self.requireSeen(path, on: route)
        } else if try await !route.writer.visibleList(path, in: route.storage).isEmpty {
          throw .directoryNotEmpty(path)
        }
      }
      do throws(TransportError) {
        try await route.session.delete(path, in: route.storage, expecting: checked)
      } catch .changedOnDevice {
        // Changed between the check and the delete: recorded, so FileProvider puts it back.
        _ = await route.items.observed(try await route.session.item(at: path, in: route.storage))
        throw .changedOnDevice(path)
      } catch .directoryNotEmpty {
        try await Self.recordArrivals(in: path, recursive: recursive, on: route)
        throw .directoryNotEmpty(path)
      }
      await route.items.removed(path)
    }
  }

  /// Runs `body` on the domain's route inside its gate, then signals the domain's working set if
  /// `body` recorded a change, even one followed by a failure.
  func gated<T: Sendable>(
    _ domain: String, _ body: (DomainController.Route) async throws(TransportError) -> T
  ) async throws(TransportError) -> T {
    let route = try await domains.route(domain)
    let (result, changed) = await route.items.gate.run {
      () async -> (Result<T, TransportError>, Bool) in
      let before = await route.items.changeCount
      let result: Result<T, TransportError>
      do throws(TransportError) {
        result = .success(try await body(route))
      } catch {
        result = .failure(error)
      }
      return (result, await route.items.changeCount != before)
    }
    await route.release()
    if changed {
      await domains.signal(domain)
    }
    if case .failure(.storageNotFound) = result {
      // The device is still attached but the storage is gone (an SD card taken out). Its
      // storages are read again, so the domain disconnects rather than looking empty.
      await hub.recheck(route.storage.device)
    }
    return try result.get()
  }

  static let workingSetPageSize = 500
}

extension AgentService {
  /// The menu's status, once the hub has scanned.
  func status() async -> StatusReport {
    await hub.firstScan()
    return StatusReport(
      devices: await hub.devices(), provider: await domains.providerState(),
      transfers: await transfers.list(),
      awaitingAuthorization: await hub.awaitingAuthorization(),
      adbStatus: await hub.adbStatus(), awaitingUSBDebugging: await hub.awaitingUSBDebugging(),
      remembered: await wireless?.remembered() ?? [],
      unconfirmed: await wireless?.unconfirmed() ?? [],
      recordings: await tools?.recordingsRunning() ?? [],
      usbWatchFailed: usbWatch?.failed ?? false, sessions: await hub.heldSessions())
  }
}

extension AgentService {
  /// Whether the request works on a Finder location's device, so it waits for the device's
  /// session behind whatever runs there, a transfer on another of its storages included, and
  /// starts only when its turn comes (see `RequestCancellation.takeTurn()`).
  static func waitsForTheDevice(_ request: AgentRequest) -> Bool {
    switch request {
    case .item, .list, .fetch, .create, .rename, .move, .replaceContents, .delete, .workingSet,
      .sendFile:
      true
    case .status, .devices, .recheck, .recheckADB, .connectAddress, .pair, .connectWireless,
      .enableWireless, .forgetWireless, .confirmWireless, .ignoreWireless, .installAPK,
      .screenshot, .startRecording, .stopRecording, .saveRecording, .discardRecording,
      .startLogcat, .stopLogcat, .forwards, .addForward, .removeForward, .deviceInfo,
      .shellTarget, .refresh, .eject, .removeAllDomains, .changes:
      false
    }
  }
}

extension AgentService {
  public nonisolated func text(for refusal: Refusal) -> String {
    switch refusal {
    case .badRequest: String(localized: AgentText.badRequest)
    case .notAllowed: String(localized: AgentText.notAllowed)
    }
  }
}
