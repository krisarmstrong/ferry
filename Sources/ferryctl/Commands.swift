import ArgumentParser
import DeviceKit
import Foundation
import MTPTransport

struct DeviceOptions: ParsableArguments {
  @Option(help: "Serial of the phone to use. Defaults to the first one found.")
  var device: String?
}

struct StorageOptions: ParsableArguments {
  @Option(help: "Description of the storage to use. Defaults to the first one.")
  var storage: String?
}

/// What a command needs to act on one storage of one phone.
struct Target {
  let session: any DeviceSession
  let writer: SafeWriter
  let storage: StorageID
}

private func message(for error: TransportError) -> String {
  switch error {
  case .noDeviceConnected: "No phone is connected."
  case .deviceNotFound(let id): "No phone with serial \(id.serial) is connected."
  case .noStorage: "The phone reports no storage."
  case .storageNotFound(let name): "The phone has no storage \"\(name)\"."
  case .deviceBusy:
    "Another app is using the phone (Image Capture, Preview, Photos or a sync app). "
      + "Quit it and replug, or see docs/spikes/2026-11-ptpcamerad.md."
  case .deviceLocked: "Unlock your phone and choose \"File transfer\"."
  case .deviceDisconnected: "The phone was disconnected."
  case .notFound(let path): "\(path) does not exist on the phone."
  case .alreadyExists(let path): "\(path) already exists on the phone. Use --replace to overwrite."
  case .invalidName(let name): "\"\(name)\" is not a valid name."
  case .unsupported(let what): "The phone does not support this: \(what)."
  case .insufficientSpace(let needed, let free):
    "Not enough space on the phone: need \(needed) bytes, \(free) free."
  case .fileTooLargeForStorage(let size):
    "The phone's storage cannot hold a file of \(size) bytes."
  case .sizeMismatch(let expected, let actual):
    "The phone stored \(actual) bytes instead of \(expected)."
  case .nameChangedByDevice(let requested, let actual):
    "The phone saved \"\(requested)\" as \"\(actual)\"."
  case .cancelled: "Cancelled."
  case .io(let detail): "I/O error: \(detail)"
  }
}

/// Prints tab-separated fields, each with its control characters made visible.
private func show(_ fields: String...) {
  print(fields.map(DisplayText.escaped).joined(separator: "\t"))
}

/// Opens the chosen phone and storage, runs `body`, closes the session, and turns any failure
/// into one stderr line and exit status 1.
private func withTarget(
  _ device: DeviceOptions, _ storage: StorageOptions? = nil,
  _ body: (Target) async throws -> Void
) async throws {
  do {
    let session = try await open(device)
    do {
      let id = try DeviceSelection.pickStorage(
        description: storage?.storage, from: await session.storages()
      ).id
      try await body(Target(session: session, writer: SafeWriter(session: session), storage: id))
    } catch {
      await session.close()
      throw error
    }
    await session.close()
  } catch {
    throw report(error)
  }
}

private func report(_ error: any Error) -> ExitCode {
  let text = (error as? TransportError).map(message(for:)) ?? error.localizedDescription
  FileHandle.standardError.write(Data((DisplayText.escaped(text) + "\n").utf8))
  return .failure
}

private func open(_ options: DeviceOptions) async throws -> any DeviceSession {
  let transport = MTPTransport()
  let device = try DeviceSelection.pickDevice(
    serial: options.device, from: await transport.connectedDevices())
  return try await transport.open(device.id)
}

private func path(_ string: String) throws -> RemotePath {
  try RemotePath(string)
}

struct Devices: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "List connected phones.")

  func run() async throws {
    do {
      for device in try DeviceSelection.requireAny(await MTPTransport().connectedDevices()) {
        show(device.id.serial, "\(device.manufacturer) \(device.model)")
      }
    } catch {
      throw report(error)
    }
  }
}

struct Storages: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "List a phone's storages.")
  @OptionGroup var device: DeviceOptions

  func run() async throws {
    try await withTarget(device) { target in
      for storage in try await target.session.storages() {
        show(storage.description, "\(storage.free) free of \(storage.capacity) bytes")
      }
    }
  }
}

struct List: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ls", abstract: "List a folder on the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Argument(help: "Remote folder, such as /DCIM.") var folder: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      for item in try await target.writer.visibleList(path(folder), in: target.storage) {
        let kind = item.kind == .folder ? "d" : "-"
        show(kind, "\(item.size)", item.path.name ?? "/")
      }
    }
  }
}

/// `get` would overwrite a file on the Mac without `--replace`.
struct LocalFileExists: LocalizedError {
  let path: String

  var errorDescription: String? {
    "\(path) already exists on this Mac. Use --replace to overwrite."
  }
}

struct Get: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Copy a file from the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Flag(help: "Replace the local file if it already exists.") var replace = false
  @Argument var remote: String
  @Argument var local: String

  func run() async throws {
    let destination = URL(fileURLWithPath: local)
    try await withTarget(device, storage) { target in
      if !replace, FileManager.default.fileExists(atPath: destination.path) {
        throw LocalFileExists(path: destination.path)
      }
      try await target.session.download(
        path(remote), in: target.storage, to: destination, progress: { _, _ in true })
    }
  }
}

struct Put: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Copy a file to the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Flag(help: "Replace the file if it already exists.") var replace = false
  @Argument var local: String
  @Argument var remote: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      _ = try await target.writer.write(
        from: URL(fileURLWithPath: local), to: path(remote), in: target.storage,
        replacing: replace, progress: { _, _ in true })
    }
  }
}

struct MakeFolder: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mkdir", abstract: "Create a folder on the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Argument var folder: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      _ = try await target.session.makeFolder(path(folder), in: target.storage)
    }
  }
}

struct Move: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mv", abstract: "Move an item into another folder on the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Argument var item: String
  @Argument var folder: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      _ = try await target.session.move(
        path(item), toFolder: path(folder), in: target.storage)
    }
  }
}

struct Rename: AsyncParsableCommand {
  static let configuration = CommandConfiguration(abstract: "Rename an item on the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Argument var item: String
  @Argument var name: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      _ = try await target.session.rename(path(item), to: name, in: target.storage)
    }
  }
}

struct Remove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "rm", abstract: "Delete a file or folder (with its contents) on the phone.")
  @OptionGroup var device: DeviceOptions
  @OptionGroup var storage: StorageOptions
  @Argument var item: String

  func run() async throws {
    try await withTarget(device, storage) { target in
      try await target.session.delete(path(item), in: target.storage)
    }
  }
}
