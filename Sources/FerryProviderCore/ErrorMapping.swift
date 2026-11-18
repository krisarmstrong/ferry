import DeviceKit
import FileProvider
import Foundation

/// Turns transport failures into errors FileProvider acts on. FileProvider retries
/// `.serverUnreachable` once the domain is signalled again, asks for sign-in on
/// `.notAuthenticated`, and shows anything else to the user, so only a failure it has a remedy
/// for gets one of its codes.
public enum ErrorMapping {
  /// The domain of errors that carry only a description.
  public static let domain = "io.github.krisarmstrong.ferry"

  /// No `default`: a new `TransportError` case must be given a mapping here.
  public static func fileProviderError(_ error: TransportError) -> any Error {
    switch error {
    // The device or its storage went away, or another app holds it: it may come back.
    case .noDeviceConnected, .noStorage, .deviceBusy, .deviceDisconnected:
      return NSFileProviderError(.serverUnreachable)
    // The phone is locked or not set to share files, which the user fixes on the phone.
    case .deviceLocked:
      return NSFileProviderError(.notAuthenticated)
    // An unknown domain names a storage that no longer exists, so nothing in it does either.
    case .notFound, .storageNotFound:
      return NSFileProviderError(.noSuchItem)
    case .alreadyExists:
      return NSFileProviderError(.filenameCollision)
    case .insufficientSpace, .fileTooLargeForStorage:
      return NSFileProviderError(.insufficientQuota)
    // A name the device cannot store; Finder reports it as an invalid file name.
    case .invalidName:
      return CocoaError(.fileWriteInvalidFileName)
    case .cancelled:
      return CocoaError(.userCancelled)
    // The upload landed under another name. Saying both lets the user find it.
    case .nameChangedByDevice(let requested, let actual):
      return described(
        "The device saved “\(requested)” as “\(actual)”.", code: 1)
    // The domain's own device not being attached surfaces from the agent as
    // `.deviceDisconnected`; this names a device chosen by serial, which a domain never does.
    case .deviceNotFound(let id):
      return described("No device with serial \(id.serial) is connected.", code: 2)
    case .unsupported(let what):
      return described("The device does not support \(what).", code: 3)
    case .sizeMismatch(let expected, let actual):
      return described(
        "The device stored \(actual) bytes where \(expected) were sent.", code: 4)
    case .io(let message):
      return described(message, code: 5)
    }
  }

  private static func described(_ description: String, code: Int) -> NSError {
    NSError(domain: domain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
  }
}
