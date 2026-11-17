import DeviceKit
import Foundation

/// A request from the app or the FileProvider extension to the agent, sent as JSON.
///
/// It arrives from a sandboxed process the agent does not control. The listener admits only
/// Ferry-signed peers, but `fetch`, `create` and `replaceContents` still carry file URLs the
/// peer chose: the agent must check they lie inside the app-group container before touching
/// them. `RemotePath` rejects `..` and empty components when decoded.
public enum AgentRequest: Codable, Sendable, Equatable {
  /// Answered with `.status(devices:providerEnabled:)`.
  case status
  case recheck(DeviceID)
  case eject(DeviceID)
  case removeAllDomains
  case item(domain: String, path: RemotePath)
  case list(domain: String, folder: RemotePath)
  /// Downloads `path` to `to`, a file URL inside the app-group container.
  case fetch(domain: String, path: RemotePath, to: URL)
  /// Uploads `from`, a file URL inside the app-group container, or makes a folder.
  case create(domain: String, path: RemotePath, from: URL?, isFolder: Bool)
  case rename(domain: String, path: RemotePath, to: String)
  case move(domain: String, path: RemotePath, toFolder: RemotePath)
  /// Replaces the file at `path` with `from`, a file URL inside the app-group container.
  case replaceContents(domain: String, path: RemotePath, from: URL)
  case delete(domain: String, path: RemotePath)
}

public enum AgentResponse: Codable, Sendable, Equatable {
  case status(devices: [AttachedDevice], providerEnabled: Bool)
  case item(RemoteItem)
  case items([RemoteItem])
  case done
  case failure(TransportError)
}
