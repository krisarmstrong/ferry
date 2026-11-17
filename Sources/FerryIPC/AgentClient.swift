import DeviceKit
import Foundation
import os

/// Sends requests to the agent. A protocol so the extension's logic can run against a fake.
public protocol AgentSending: Sendable {
  func send(_ request: AgentRequest) async throws(TransportError) -> AgentResponse
}

/// An XPC client of the agent.
///
/// launchd may relaunch the agent at any time, so a lost connection is replaced on the next
/// `send`. Calls in flight when it is lost throw `.deviceDisconnected`; the agent's own
/// failures come back as `.failure` responses.
public actor AgentClient: AgentSending {
  private enum Target {
    case machService(String)
    case endpoint(NSXPCListenerEndpoint)
  }

  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "AgentClient")

  private let target: Target
  private var connection: NSXPCConnection?

  public init(machServiceName: String) {
    target = .machService(machServiceName)
  }

  /// Connects to an anonymous listener in the same process.
  init(endpoint: NSXPCListenerEndpoint) {
    target = .endpoint(endpoint)
  }

  public func send(_ request: AgentRequest) async throws(TransportError) -> AgentResponse {
    let data: Data
    do {
      data = try JSONEncoder().encode(request)
    } catch {
      throw .io("cannot encode request: \(error.localizedDescription)")
    }
    let connection = currentConnection()
    let reply = await awaitReply { reply, failed in
      guard let proxy = connection.remoteObjectProxyWithErrorHandler(failed) as? any AgentXPC
      else {
        failed(TransportError.io("agent proxy has the wrong interface"))
        return
      }
      proxy.send(data, reply: reply)
    }
    let replyData: Data
    switch reply {
    case .success(let data):
      replyData = data
    case .failure(let error):
      // An interrupted connection stays usable: launchd relaunches the agent on the next
      // message. An invalid one never recovers, so the next send must open a fresh one.
      if (error as NSError).code == NSXPCConnectionInvalid {
        dropConnection(ObjectIdentifier(connection))
      }
      throw .deviceDisconnected
    }
    do {
      return try JSONDecoder().decode(AgentResponse.self, from: replyData)
    } catch {
      Self.log.error("undecodable reply from agent: \(error, privacy: .private)")
      throw .io("bad response from agent")
    }
  }

  private func currentConnection() -> NSXPCConnection {
    if let connection { return connection }
    let made =
      switch target {
      case .machService(let name): NSXPCConnection(machServiceName: name)
      case .endpoint(let endpoint): NSXPCConnection(listenerEndpoint: endpoint)
      }
    made.remoteObjectInterface = NSXPCInterface(with: AgentXPC.self)
    let id = ObjectIdentifier(made)
    made.invalidationHandler = { [weak self] in
      Task { await self?.dropConnection(id) }
    }
    made.resume()
    connection = made
    return made
  }

  private func dropConnection(_ id: ObjectIdentifier) {
    guard let connection, ObjectIdentifier(connection) == id else { return }
    Self.log.info("connection to agent invalidated")
    self.connection = nil
  }
}
