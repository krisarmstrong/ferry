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
    guard let serial = await target(id) else { return .failure(.notOverADB) }
    do throws(ADBError) {
      return .success(try await device.forwards(serial: serial))
    } catch {
      throw Self.transportError(error)
    }
  }

  public func addForward(_ id: DeviceID, _ forward: PortForward) async throws(TransportError)
    -> Outcome
  {
    guard forward.isAllowed else { return .failed(.invalidPort) }
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    do throws(ADBError) {
      try await device.addForward(serial: serial, forward)
      return .done
    } catch {
      return try Self.forwardOutcome(error)
    }
  }

  /// adb removes a forward by its Mac port whichever device owns it, so one the device's own
  /// list does not show is left alone.
  public func removeForward(_ id: DeviceID, local: UInt16) async throws(TransportError) -> Outcome {
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    do throws(ADBError) {
      guard try await device.forwards(serial: serial).contains(where: { $0.local == local }) else {
        return .failed(.forwardFailed("listener 'tcp:\(local)' not found"))
      }
      try await device.removeForward(serial: serial, local: local)
      return .done
    } catch {
      return try Self.forwardOutcome(error)
    }
  }

  /// adb's refusal in adb's words, at most 200 characters; a device or server lost is a
  /// disconnected device, as for every tool.
  private static func forwardOutcome(_ error: ADBError) throws(TransportError) -> Outcome {
    guard case .failed(let message) = error else { throw transportError(error) }
    if message.contains("offline") || message.contains("unauthorized") {
      throw transportError(error)
    }
    return .failed(.forwardFailed(String(message.prefix(200))))
  }

  public func deviceInfo(_ id: DeviceID) async throws(TransportError)
    -> Result<AndroidDeviceInfo, ToolFailure>
  {
    guard let serial = await target(id) else { return .failure(.notOverADB) }
    do throws(ADBError) {
      return .success(try await device.deviceInfo(serial: serial))
    } catch {
      throw Self.transportError(error)
    }
  }

  /// The program and serial for `adb -s <serial> shell` in Terminal.
  public func shellTarget(_ id: DeviceID) async throws(TransportError)
    -> Result<ShellTarget, ToolFailure>
  {
    guard let serial = await target(id) else { return .failure(.notOverADB) }
    guard let adb = device.adbPath() else { return .failure(.adbNotFound) }
    guard let shell = ShellTarget(adb: adb.path, serial: serial) else {
      throw .unsupported("a shell for this device")
    }
    return .success(shell)
  }
}
