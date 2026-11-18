import DeviceKit
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// FileProvider accepts errors only in its own domain or Cocoa's, and logs anything else as a
/// critical fault. Every error Ferry hands it is one of those, with a description to show.
struct ErrorMappingTests {
  static func samples() throws -> [TransportError] {
    [
      .noDeviceConnected, .deviceNotFound(DeviceID(serial: "S1")), .noStorage,
      .storageNotFound("SD card"), .deviceBusy, .deviceLocked, .deviceDisconnected,
      .notFound(try RemotePath("/a")), .unknownItem, .alreadyExists(try RemotePath("/a")),
      .invalidName("a/b"), .unsupported("copy"), .insufficientSpace(needed: 2, free: 1),
      .fileTooLargeForStorage(size: 5), .sizeMismatch(expected: 2, actual: 1),
      .nameChangedByDevice(requested: "Résumé.txt", actual: "RESUME.TXT"), .cancelled,
      .io("pipe broke"), .downloadSizeMismatch(listed: 7, received: 3),
      .directoryNotEmpty(try RemotePath("/a")), .changedOnDevice(try RemotePath("/a")),
      .macDiskFull(needed: 2, free: 1), .folderTooDeep(try RemotePath("/Deep")),
      .readOnly(try RemotePath("/Notes.rtfd/TXT.rtf")),
    ]
  }

  static let allowedDomains: Set<String> = [NSFileProviderErrorDomain, NSCocoaErrorDomain]

  @Test func everyTransportErrorIsInADomainFileProviderAccepts() throws {
    let samples = try Self.samples()
    // One sample per case, each checked against `expected(_:)`, whose switch has no default.
    #expect(Set(samples.map { "\($0)".prefix { $0 != "(" } }).count == samples.count)
    for sample in samples {
      let mapped = ErrorMapping.fileProviderError(sample) as NSError
      #expect(Self.allowedDomains.contains(mapped.domain), "\(sample): \(mapped.domain)")
      #expect(!mapped.localizedDescription.isEmpty, "\(sample)")
      switch expected(sample) {
      case .fileProvider(let code):
        #expect(mapped.domain == NSFileProviderErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
      case .cocoa(let code, let fragments):
        #expect(mapped.domain == NSCocoaErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
        for fragment in fragments {
          #expect(mapped.localizedDescription.contains(fragment), "\(sample)")
        }
      }
    }
  }

  /// The FileProvider headers ask for the error no code represents as the underlying error of
  /// the `NSXPCConnectionReplyInvalid` Cocoa error.
  @Test func anIOFailureCarriesItselfAsTheUnderlyingError() {
    let failure = TransportError.io("pipe broke")
    let mapped = ErrorMapping.fileProviderError(failure) as NSError

    #expect(mapped.code == CocoaError.Code.xpcConnectionReplyInvalid.rawValue)
    #expect(mapped.localizedDescription == "pipe broke")
    #expect(mapped.userInfo[NSUnderlyingErrorKey] as? TransportError == failure)
  }

  /// The last guard before an error reaches FileProvider: errors from elsewhere (POSIX, a
  /// custom domain) become Cocoa errors that keep their description and the original.
  @Test func anyOtherErrorBecomesACocoaError() {
    let posix = POSIXError(.EACCES)
    let custom = NSError(
      domain: "io.example.custom", code: 7,
      userInfo: [NSLocalizedDescriptionKey: "Something odd"])
    for error in [posix as any Error, custom] {
      let safe = ErrorMapping.forFileProvider(error) as NSError
      #expect(Self.allowedDomains.contains(safe.domain))
      #expect(!safe.localizedDescription.isEmpty)
      #expect(
        (safe.userInfo[NSUnderlyingErrorKey] as? NSError)?.domain == (error as NSError).domain)
    }
    #expect(ErrorMapping.forFileProvider(custom).localizedDescription == "Something odd")
    let accepted = NSFileProviderError(.noSuchItem)
    #expect((ErrorMapping.forFileProvider(accepted) as NSError) == (accepted as NSError))
    #expect(
      (ErrorMapping.forFileProvider(TransportError.unknownItem) as NSError).domain
        == NSFileProviderErrorDomain)
  }

  private enum Expected {
    case fileProvider(NSFileProviderError.Code)
    case cocoa(CocoaError.Code, [String])
  }

  /// No `default`: a new `TransportError` case must be given an expectation here.
  private func expected(_ error: TransportError) -> Expected {
    switch error {
    case .noDeviceConnected, .noStorage, .deviceBusy, .deviceDisconnected, .storageNotFound,
      .deviceNotFound:
      .fileProvider(.serverUnreachable)
    case .deviceLocked: .fileProvider(.notAuthenticated)
    case .notFound, .unknownItem: .fileProvider(.noSuchItem)
    case .alreadyExists: .fileProvider(.filenameCollision)
    case .insufficientSpace, .fileTooLargeForStorage: .fileProvider(.insufficientQuota)
    case .directoryNotEmpty: .fileProvider(.directoryNotEmpty)
    case .changedOnDevice: .fileProvider(.localVersionConflictingWithServer)
    case .invalidName: .cocoa(.fileWriteInvalidFileName, [])
    case .cancelled: .cocoa(.userCancelled, [])
    case .macDiskFull: .cocoa(.fileWriteOutOfSpace, [])
    case .nameChangedByDevice(let requested, let actual):
      .cocoa(.fileWriteInvalidFileName, [requested, actual])
    case .unsupported(let what): .cocoa(.featureUnsupported, [what])
    case .sizeMismatch: .cocoa(.fileWriteUnknown, ["2", "1"])
    case .downloadSizeMismatch: .cocoa(.fileReadCorruptFile, ["7", "3"])
    case .io(let message): .cocoa(.xpcConnectionReplyInvalid, [message])
    case .folderTooDeep: .cocoa(.featureUnsupported, ["Deep", "64"])
    case .readOnly: .fileProvider(.cannotSynchronize)
    }
  }
}
