import DeviceKit
import FileProvider
import Foundation

/// Turns failures into errors FileProvider acts on. FileProvider retries `.serverUnreachable`
/// once the domain is signalled again, asks for sign-in on `.notAuthenticated`, and shows
/// anything else to the user, so only a failure it has a remedy for gets one of its codes.
///
/// FileProvider accepts errors only in its own domain or Cocoa's, and logs any other as a fault.
/// A failure with no code of its own is a Cocoa error carrying the description to show.
public enum ErrorMapping {
  /// No `default`: a new `TransportError` case must be given a mapping here.
  public static func fileProviderError(_ error: TransportError) -> any Error {
    switch error {
    // The device or its storage went away, or another app holds it: it may come back. A storage
    // gone from a device still attached (an SD card taken out) is the whole domain, never one
    // missing item: "no such item" would make FileProvider delete the domain's items locally.
    // The agent disconnects that domain. A device named by serial that is not attached is the
    // same: a domain never names one, so it is only ever a device that went away.
    case .noDeviceConnected, .noStorage, .deviceBusy, .deviceDisconnected, .storageNotFound,
      .deviceNotFound:
      return NSFileProviderError(.serverUnreachable)
    // The phone is locked or not set to share files, which the user fixes on the phone.
    case .deviceLocked:
      return NSFileProviderError(.notAuthenticated)
    // The item is gone. An unknown or not yet adopted domain is never this: the agent reports it
    // as `.deviceDisconnected`.
    case .notFound, .unknownItem:
      return NSFileProviderError(.noSuchItem)
    case .alreadyExists:
      return NSFileProviderError(.filenameCollision)
    case .insufficientSpace, .fileTooLargeForStorage:
      return NSFileProviderError(.insufficientQuota)
    case .directoryNotEmpty:
      return NSFileProviderError(.directoryNotEmpty)
    // A replace asked to fail on conflict. A delete's conflict is `.deletionRejected`, which
    // `ProviderBackend.delete` builds with the device's item.
    case .changedOnDevice:
      return NSFileProviderError(.localVersionConflictingWithServer)
    // A name the device cannot store; Finder reports it as an invalid file name.
    case .invalidName:
      return CocoaError(.fileWriteInvalidFileName)
    case .cancelled:
      return CocoaError(.userCancelled)
    case .macDiskFull:
      return CocoaError(.fileWriteOutOfSpace)
    // The upload landed under another name. Saying both lets the user find it.
    case .nameChangedByDevice(let requested, let actual):
      return described(
        .fileWriteInvalidFileName, "The device saved “\(requested)” as “\(actual)”.")
    case .unsupported(let what):
      return described(.featureUnsupported, "The device does not support \(what).")
    case .sizeMismatch(let expected, let actual):
      return described(
        .fileWriteUnknown, "The device stored \(actual) bytes where \(expected) were sent.")
    case .downloadSizeMismatch(let listed, let received):
      return described(
        .fileReadCorruptFile,
        "The device sent \(received) bytes of a file it lists as \(listed) bytes.")
    case .folderTooDeep(let path):
      return described(
        .featureUnsupported,
        "“\(path.name ?? path.description)” holds folders nested more than "
          + "\(RemotePath.maxTreeDepth) deep, which Ferry does not delete.")
    // No Cocoa code describes it: the one the FileProvider headers name for such errors.
    case .io(let message):
      return described(.xpcConnectionReplyInvalid, message)
    }
  }

  /// `error` as FileProvider accepts it: unchanged in its own domain or Cocoa's, a
  /// `TransportError` mapped as above, and anything else (POSIX, another domain) a Cocoa error
  /// with the code the FileProvider headers name for errors no code represents, keeping the
  /// description and the original as the underlying error. The extension passes every error it
  /// returns through this.
  public static func forFileProvider(_ error: any Error) -> any Error {
    if let transport = error as? TransportError { return fileProviderError(transport) }
    let nsError = error as NSError
    guard nsError.domain != NSFileProviderErrorDomain, nsError.domain != NSCocoaErrorDomain else {
      return error
    }
    return NSError(
      domain: NSCocoaErrorDomain, code: CocoaError.Code.xpcConnectionReplyInvalid.rawValue,
      userInfo: [
        NSLocalizedDescriptionKey: nsError.localizedDescription, NSUnderlyingErrorKey: nsError,
      ])
  }

  private static func described(_ code: CocoaError.Code, _ description: String) -> CocoaError {
    CocoaError(code, userInfo: [NSLocalizedDescriptionKey: description])
  }
}
