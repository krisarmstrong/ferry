import DeviceKit
import Foundation
import Testing

@testable import ADBTransport

/// An `ADBTransport` on a `FakeADBHub`, with a locator that finds (or does not find) adb and a
/// launcher that never runs it.
enum TransportFixture {
  static let linkRunnerSerial = "0123456789abcdef"
  static let linkRunner = DeviceID(serial: linkRunnerSerial)
  static let linkRunnerWiFi = "192.0.2.31:5555"
  static let linkRunnerInfo = DeviceInfo(
    id: linkRunner, manufacturer: "NetAlly", model: "LinkRunner G2")

  static let findsAdb = ADBLocator(
    environment: [:], home: "/nonexistent", isExecutable: { $0 == "/opt/homebrew/bin/adb" })

  /// A device whose properties say it is `serial`.
  static func android(
    serial: String, manufacturer: String = "NetAlly", model: String = "LinkRunner G2"
  ) -> FakeAndroid {
    let device = FakeAndroid()
    device.state.withLock {
      $0.properties = [
        "ro.serialno": serial, "ro.product.manufacturer": manufacturer, "ro.product.model": model,
      ]
    }
    return device
  }

  static func transport(port: UInt16, locator: ADBLocator = findsAdb) -> ADBTransport {
    ADBTransport(
      host: ADBHost(
        port: port, locator: locator, launcher: { _ in },
        backoff: Backoff(initial: .milliseconds(20), maximum: .milliseconds(100))),
      locator: locator)
  }

  /// A hub serving `entries`, started on a free port; the caller kills it.
  static func hub(_ entries: [FakeADBHub.Entry]) async throws -> FakeADBHub {
    let hub = FakeADBHub(entries)
    try await hub.start()
    return hub
  }

  /// How many times `device` was asked for `property`.
  static func lookups(of property: String, on device: FakeAndroid) -> Int {
    device.state.withLock { $0.commands.filter { $0 == ["getprop", property] }.count }
  }

  typealias Outcome<Value> = Result<Value, TransportError>

  static func storages(_ session: any DeviceSession) async -> Outcome<[StorageInfo]> {
    do throws(TransportError) {
      return .success(try await session.storages())
    } catch {
      return .failure(error)
    }
  }

  static func open(_ transport: ADBTransport, _ id: DeviceID) async -> Outcome<any DeviceSession> {
    do throws(TransportError) {
      return .success(try await transport.open(id))
    } catch {
      return .failure(error)
    }
  }
}

extension Result {
  var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
