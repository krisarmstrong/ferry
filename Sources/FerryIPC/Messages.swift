import DeviceKit
import Foundation

/// A request from the app or the FileProvider extension to the agent, sent as JSON.
///
/// It arrives from a sandboxed process the agent does not control. File contents never travel as
/// paths: `fetch`, `create` (of a file) and `replaceContents` come with an open file descriptor,
/// so the agent never opens a file the peer named. `RemotePath` rejects `..` and empty
/// components when decoded.
public enum AgentRequest: Codable, Sendable, Equatable {
  /// Answered with `.status(devices:providerEnabled:)`.
  case status
  case recheck(DeviceID)
  case eject(DeviceID)
  case removeAllDomains
  case item(domain: String, path: RemotePath)
  case list(domain: String, folder: RemotePath)
  /// Downloads `path` into the writable file sent with the request.
  case fetch(domain: String, path: RemotePath)
  /// Uploads the readable file sent with the request, or makes a folder (sent with no file).
  case create(domain: String, path: RemotePath, isFolder: Bool)
  case rename(domain: String, path: RemotePath, to: String)
  case move(domain: String, path: RemotePath, toFolder: RemotePath)
  /// Replaces the file at `path` with the readable file sent with the request.
  case replaceContents(domain: String, path: RemotePath)
  case delete(domain: String, path: RemotePath)
}

public enum AgentResponse: Codable, Sendable, Equatable {
  case status(devices: [AttachedDevice], providerEnabled: Bool)
  case item(RemoteItem)
  case items([RemoteItem])
  case done
  case failure(TransportError)
}
