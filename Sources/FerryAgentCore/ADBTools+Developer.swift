import ADBTransport
import DeviceKit
import FerryIPC
import Foundation

/// Port forwards, device info and the shell's target, for a device served over ADB by the route
/// its session uses. The ports are checked here, not only on screen.
extension ADBTools {
  public func forwards(_ id: DeviceID) async throws(TransportError)
    -> Result<[PortForward], ToolFailure>
  {
    guard let route = await target(id) else { return .failure(.notOverADB) }
    do throws(ADBError) {
      return .success(try await device.forwards(route: route))
    } catch {
      throw Self.transportError(error)
    }
  }

  public func addForward(_ id: DeviceID, _ forward: PortForward) async throws(TransportError)
    -> Outcome
  {
    guard forward.isAllowed else { return .failed(.invalidPort) }
    guard let route = await target(id) else { return .failed(.notOverADB) }
    do throws(ADBError) {
      try await device.addForward(route: route, forward)
      return .done
    } catch {
      return try Self.forwardOutcome(error)
    }
  }

  /// adb removes a forward by its Mac port whichever device owns it, so one the device's own
  /// list does not show is left alone.
  public func removeForward(_ id: DeviceID, local: UInt16) async throws(TransportError) -> Outcome {
    guard let route = await target(id) else { return .failed(.notOverADB) }
    do throws(ADBError) {
      guard try await device.forwards(route: route).contains(where: { $0.local == local }) else {
        return .failed(.forwardNotFound)
      }
      try await device.removeForward(route: route, local: local)
      return .done
    } catch {
      return try Self.forwardOutcome(error)
    }
  }

  /// adb's refusal in adb's words, at most 200 characters; a device or server lost is a
  /// disconnected device, as for every tool.
  private static func forwardOutcome(_ error: ADBError) throws(TransportError) -> Outcome {
    guard case .failed(let message) = error else { throw transportError(error) }
    // The device went between the list and the request: a lost device, not a refused forward.
    if message.hasPrefix("device ") { throw .deviceDisconnected }
    if message.contains("offline") || message.contains("unauthorized") {
      throw transportError(error)
    }
    if message.hasPrefix("listener ") { return .failed(.forwardNotFound) }
    return .failed(.forwardFailed(String(message.prefix(200))))
  }

  public func deviceInfo(_ id: DeviceID) async throws(TransportError)
    -> Result<AndroidDeviceInfo, ToolFailure>
  {
    guard let route = await target(id) else { return .failure(.notOverADB) }
    do throws(ADBError) {
      return .success(try await device.deviceInfo(route: route))
    } catch {
      throw Self.transportError(error)
    }
  }

  /// The address the tools reach the device at over the network: its route's `host:port`. A USB
  /// serial and an mDNS name have no port, so they are not one.
  public func networkAddress(of id: DeviceID) async -> WirelessEndpoint? {
    guard let route = await target(id) else { return nil }
    return WirelessEndpoint(parsing: route.serial, defaultPort: nil)
  }

  /// The program and serial for `adb -s <serial> shell` in Terminal.
  public func shellTarget(_ id: DeviceID) async throws(TransportError)
    -> Result<ShellTarget, ToolFailure>
  {
    guard let route = await target(id) else { return .failure(.notOverADB) }
    guard let adb = device.shellADB() else { return .failure(.adbNotFound) }
    guard
      let shell = ShellTarget(
        adb: adb.url.path, serial: route.serial, transportID: route.transportID,
        runsServer: adb.runsServer)
    else {
      throw .unsupported("a shell for this device")
    }
    return .success(shell)
  }
}
