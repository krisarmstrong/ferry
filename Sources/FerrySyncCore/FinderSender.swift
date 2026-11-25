import DeviceKit
import FerryIPC
import FerryText
import Foundation

/// What the user is told when a Finder action ends. Finder Sync has no progress UI, so this is
/// the only word of it.
public struct FinderNotice: Equatable, Sendable {
  public let title: String
  public let body: String
  /// For a failure, the title's catalog key, which names its entry in Ferry's Help.
  public let help: String?

  public init(title: String, body: String, help: String? = nil) {
    self.title = title
    self.body = body
    self.help = help
  }
}

/// Carries out a Finder menu action through the agent.
///
/// The extension opens each file itself and sends it as a descriptor, opened without following a
/// link and checked to be a regular file after the open, so the agent never opens a path a client
/// chose (see `AgentRequest`). Files go one at a time, in the order Finder selected them.
public struct FinderSender: Sendable {
  private let agent: any AgentSending

  public init(agent: any AgentSending) {
    self.agent = agent
  }

  /// Sends or installs every item of `urls` on the device, and says how it went. `deviceName`
  /// is the name the menu showed (see `FinderMenu.displayNames(of:)`).
  public func perform(_ action: FinderAction, on urls: [URL], deviceName: String) async
    -> FinderNotice
  {
    await performReporting(action, on: urls, deviceName: deviceName).notice
  }

  /// Like `perform(_:on:deviceName:)`, also saying whether any item failed, for the Ferry menu,
  /// which shows a failure as an error.
  public func performReporting(_ action: FinderAction, on urls: [URL], deviceName: String) async
    -> (notice: FinderNotice, failed: Bool)
  {
    var outcomes: [Outcome] = []
    for url in urls {
      outcomes.append(await perform(action, on: url))
    }
    let failed = outcomes.contains { if case .failed = $0.result { true } else { false } }
    return (Self.notice(for: outcomes, of: action, deviceName: deviceName), failed)
  }

  // MARK: One item

  enum ItemResult: Equatable {
    /// Done; for a sent file, the name it got on the device.
    case done(savedAs: String?)
    case failed(String)
  }

  struct Outcome: Equatable {
    /// The item's name on the Mac, escaped for display.
    let name: String
    let result: ItemResult
  }

  private func perform(_ action: FinderAction, on url: URL) async -> Outcome {
    let name = url.lastPathComponent
    let shown = DisplayText.escaped(name)
    if let refusal = LocalItem.refusal(for: url) {
      return Outcome(name: shown, result: .failed(refusal.message))
    }
    let handle: FileHandle
    switch Self.openForSending(url) {
    case .success(let opened): handle = opened
    case .failure(let failure):
      return Outcome(name: shown, result: .failed(failure.refusal?.message ?? Self.unreadable))
    }
    defer { try? handle.close() }
    let request: AgentRequest =
      switch action {
      case .send(let id): .sendFile(id, name: name)
      case .install(let id): .installAPK(id, name: name)
      }
    let result: ItemResult
    do {
      result = Self.result(of: try await agent.send(request, file: handle))
    } catch {
      result = .failed(Self.message(for: error))
    }
    return Outcome(name: shown, result: result)
  }

  /// Opens the file for reading without following a link, then checks what was opened: the
  /// item may have changed since `LocalItem` inspected it. Non-blocking, so a FIFO swapped in
  /// cannot hold the open; the flag is cleared once the file is known to be regular. A failure
  /// carries the refusal, if the item is one, or `nil` when it cannot be read.
  static func openForSending(_ url: URL) -> Result<FileHandle, OpenFailure> {
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      return .failure(OpenFailure(errno == ELOOP ? .link : nil))
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      let isFolder = info.st_mode & S_IFMT == S_IFDIR
      close(descriptor)
      return .failure(OpenFailure(isFolder ? .folder : .notAFile))
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
      close(descriptor)
      return .failure(OpenFailure(nil))
    }
    return .success(FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
  }

  struct OpenFailure: Error {
    let refusal: LocalItem.Refusal?

    init(_ refusal: LocalItem.Refusal?) {
      self.refusal = refusal
    }
  }

  private static func result(of response: AgentResponse) -> ItemResult {
    switch response {
    case .entry(let entry): .done(savedAs: entry.item.path.name.map(DisplayText.escaped))
    case .done: .done(savedAs: nil)
    case .toolFailed(let failure): .failed(PresentationText.message(for: failure))
    case .failure(let error): .failed(message(for: error))
    default: .failed(message(for: .io("unexpected reply")))
    }
  }

  /// The menu's wording, made specific where a send meets a limit the user can act on.
  static func message(for error: TransportError) -> String {
    switch error {
    case .insufficientSpace:
      String(
        localized: LocalizedStringResource(
          "The device doesn’t have enough free space.", bundle: .module))
    case .fileTooLargeForStorage:
      String(
        localized: LocalizedStringResource(
          "The file is too large for the device’s storage.", bundle: .module))
    case .invalidName:
      String(
        localized: LocalizedStringResource(
          "The device can’t store a file with that name.", bundle: .module))
    case .alreadyExists(let path) where path == downloadFolder:
      String(
        localized: LocalizedStringResource(
          """
          The device has a file named Download where its Download folder should be. Rename or \
          remove it on the device, then try again.
          """, bundle: .module))
    case .macDiskFull:
      String(
        localized: LocalizedStringResource(
          "This Mac doesn’t have enough free space to copy the file.", bundle: .module))
    default:
      PresentationText.message(for: error)
    }
  }

  /// The folder sends go into; the agent reports a file there as `.alreadyExists` of it.
  private static let downloadFolder = try? RemotePath("/Download")

  /// A file on the Mac that could not be opened for reading. The menu's Install App… says the
  /// same, with the same Help.
  public static let unreadableResource = LocalizedStringResource(
    "The file can’t be read.", bundle: .module)

  private static var unreadable: String {
    String(localized: unreadableResource)
  }
}

extension FinderSender {
  /// One line for the whole selection: what was done and where, or the first reason it was not.
  static func notice(for outcomes: [Outcome], of action: FinderAction, deviceName device: String)
    -> FinderNotice
  {
    let install = if case .install = action { true } else { false }
    if let only = outcomes.first, outcomes.count == 1 {
      return notice(for: only, install: install, device: device)
    }
    let failures = outcomes.compactMap { outcome -> (name: String, reason: String)? in
      if case .failed(let reason) = outcome.result { (outcome.name, reason) } else { nil }
    }
    let (count, done) = (outcomes.count, outcomes.count - failures.count)
    guard let (name, reason) = failures.first else {
      return install
        ? FinderNotice(
          title: String(
            localized: LocalizedStringResource(
              "Installed \(count) apps on \(device)", bundle: .module)),
          body: "")
        : FinderNotice(
          title: String(
            localized: LocalizedStringResource("Sent \(count) files to \(device)", bundle: .module)),
          body: String(localized: LocalizedStringResource("They’re in Download.", bundle: .module)))
    }
    let title =
      switch (install, done) {
      case (true, 0):
        LocalizedStringResource("Couldn’t install \(count) apps on \(device)", bundle: .module)
      case (false, 0):
        LocalizedStringResource("Couldn’t send \(count) files to \(device)", bundle: .module)
      case (true, _):
        LocalizedStringResource("Installed \(done) of \(count) on \(device)", bundle: .module)
      case (false, _):
        LocalizedStringResource("Sent \(done) of \(count) to \(device)", bundle: .module)
      }
    let failed =
      install
      ? LocalizedStringResource("“\(name)” wasn’t installed.", bundle: .module)
      : LocalizedStringResource("“\(name)” wasn’t sent.", bundle: .module)
    var sentences = [String(localized: failed), reason]
    let others = failures.count - 1
    if others > 0 {
      let more =
        install
        ? LocalizedStringResource("Also not installed: \(others).", bundle: .module)
        : LocalizedStringResource("Also not sent: \(others).", bundle: .module)
      sentences.append(String(localized: more))
    }
    // Each sentence is its own catalog entry, so no translation has to carry another's words.
    let body = sentences.joined(separator: " ")
    return FinderNotice(title: String(localized: title), body: body, help: title.key)
  }

  private static func notice(for only: Outcome, install: Bool, device: String) -> FinderNotice {
    let name = only.name
    switch (only.result, install) {
    case (.failed(let reason), true):
      let title = LocalizedStringResource(
        "Couldn’t install “\(name)” on \(device)", bundle: .module)
      return FinderNotice(title: String(localized: title), body: reason, help: title.key)
    case (.failed(let reason), false):
      let title = LocalizedStringResource("Couldn’t send “\(name)” to \(device)", bundle: .module)
      return FinderNotice(title: String(localized: title), body: reason, help: title.key)
    case (.done, true):
      return FinderNotice(
        title: String(
          localized: LocalizedStringResource("Installed “\(name)” on \(device)", bundle: .module)),
        body: "")
    case (.done(let savedAs), false):
      return FinderNotice(
        title: String(
          localized: LocalizedStringResource("Sent “\(name)” to \(device)", bundle: .module)),
        body: sentBody(name, savedAs: savedAs))
    }
  }

  private static func sentBody(_ name: String, savedAs: String?) -> String {
    guard let savedAs, savedAs != name else {
      return String(localized: LocalizedStringResource("It’s in Download.", bundle: .module))
    }
    return String(
      localized: LocalizedStringResource(
        "Download already had a file with that name, so it’s there as “\(savedAs)”.",
        bundle: .module))
  }
}
