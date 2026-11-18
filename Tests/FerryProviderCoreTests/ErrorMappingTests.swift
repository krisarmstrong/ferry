import DeviceKit
import FerryProviderCore
import FileProvider
import Foundation
import Testing

struct ErrorMappingTests {
  @Test func everyTransportErrorMaps() throws {
    let samples: [TransportError] = [
      .noDeviceConnected, .deviceNotFound(DeviceID(serial: "S1")), .noStorage,
      .storageNotFound("SD card"), .deviceBusy, .deviceLocked, .deviceDisconnected,
      .notFound(try path("/a")), .unknownItem, .alreadyExists(try path("/a")), .invalidName("a/b"),
      .unsupported("copy"), .insufficientSpace(needed: 2, free: 1),
      .fileTooLargeForStorage(size: 5), .sizeMismatch(expected: 2, actual: 1),
      .nameChangedByDevice(requested: "Résumé.txt", actual: "RESUME.TXT"), .cancelled,
      .io("pipe broke"),
    ]
    for sample in samples {
      let mapped = ErrorMapping.fileProviderError(sample) as NSError
      switch expected(sample) {
      case .fileProvider(let code):
        #expect(mapped.domain == NSFileProviderErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
      case .cocoa(let code):
        #expect(mapped.domain == NSCocoaErrorDomain, "\(sample)")
        #expect(mapped.code == code.rawValue, "\(sample)")
      case .described(let fragments):
        #expect(mapped.domain == ErrorMapping.domain, "\(sample)")
        for fragment in fragments {
          #expect(mapped.localizedDescription.contains(fragment), "\(sample)")
        }
      }
    }
  }

  private enum Expected {
    case fileProvider(NSFileProviderError.Code)
    case cocoa(CocoaError.Code)
    case described([String])
  }

  /// No `default`: a new `TransportError` case must be given an expectation here.
  private func expected(_ error: TransportError) -> Expected {
    switch error {
    case .noDeviceConnected, .noStorage, .deviceBusy, .deviceDisconnected:
      .fileProvider(.serverUnreachable)
    case .deviceLocked: .fileProvider(.notAuthenticated)
    case .notFound, .unknownItem, .storageNotFound: .fileProvider(.noSuchItem)
    case .alreadyExists: .fileProvider(.filenameCollision)
    case .insufficientSpace, .fileTooLargeForStorage: .fileProvider(.insufficientQuota)
    case .invalidName: .cocoa(.fileWriteInvalidFileName)
    case .cancelled: .cocoa(.userCancelled)
    case .nameChangedByDevice(let requested, let actual): .described([requested, actual])
    case .deviceNotFound(let id): .described([id.serial])
    case .unsupported(let what): .described([what])
    case .sizeMismatch: .described(["2", "1"])
    case .io(let message): .described([message])
    }
  }
}
