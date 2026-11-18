import DeviceKit
import Foundation
import os

/// The agent's XPC interface. Requests and replies are JSON-encoded `AgentRequest` and
/// `AgentResponse`, so the wire format is ordinary `Codable` rather than `NSSecureCoding`. A
/// request that moves file contents also carries an open file, which XPC passes as a descriptor.
@objc public protocol AgentXPC {
  /// `id` names the request in the progress the agent reports on the client's exported
  /// `AgentClientXPC`.
  func send(
    _ request: Data, id: String, file: FileHandle?, reply: @escaping @Sendable (Data) -> Void)
}

/// Serves agent requests from the app and the FileProvider extension.
public protocol AgentHandling: Sendable {
  /// `file` is the descriptor sent with the request, if any: readable for `create` and
  /// `replaceContents`, writable for `fetch`. A transfer reports its bytes to `progress`, which
  /// forwards them to the client; it never blocks.
  func handle(
    _ request: AgentRequest, file: FileHandle?, progress: @escaping TransferProgressHandler
  ) async -> AgentResponse
}

extension AgentHandling {
  /// Handles a request whose progress nobody follows.
  public func handle(_ request: AgentRequest, file: FileHandle?) async -> AgentResponse {
    await handle(request, file: file, progress: { _, _ in })
  }
}

/// Accepts connections on the agent's listener and routes their requests to a handler.
public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
  private let handler: any AgentHandling
  private let codeSigningRequirement: String?

  /// Admits only the Ferry app and its extension signed by `identity`'s team, checked on every
  /// message.
  public convenience init(handler: any AgentHandling, identity: FerryIdentity) {
    self.init(handler: handler, codeSigningRequirement: identity.clientRequirement)
  }

  /// A nil requirement admits any peer, which only an anonymous listener in tests may use.
  init(handler: any AgentHandling, codeSigningRequirement: String?) {
    self.handler = handler
    self.codeSigningRequirement = codeSigningRequirement
  }

  public func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    if let codeSigningRequirement {
      connection.setCodeSigningRequirement(codeSigningRequirement)
    }
    connection.exportedInterface = NSXPCInterface(with: AgentXPC.self)
    connection.exportedObject = AgentService(handler: handler)
    connection.remoteObjectInterface = NSXPCInterface(with: AgentClientXPC.self)
    connection.resume()
    return true
  }
}

/// The object exported on each accepted connection.
final class AgentService: NSObject, AgentXPC, Sendable {
  private static let log = Logger(
    subsystem: "io.github.krisarmstrong.ferry", category: "AgentService")

  private let handler: any AgentHandling

  init(handler: any AgentHandling) {
    self.handler = handler
  }

  func send(
    _ request: Data, id: String, file: FileHandle?, reply: @escaping @Sendable (Data) -> Void
  ) {
    // The connection the message came on, read now: it is only known while the call runs. Its
    // proxy is fetched per request, so this object keeps no reference to its own connection.
    let connection = NSXPCConnection.current()
    let client = connection?.remoteObjectProxyWithErrorHandler { _ in } as? any AgentClientXPC
    let decoded: AgentRequest
    do {
      decoded = try JSONDecoder().decode(AgentRequest.self, from: request)
    } catch {
      Self.log.error("rejected undecodable request: \(error, privacy: .private)")
      reply(Self.encode(.failure(.io("bad request"))))
      return
    }
    let reported = Reported()
    Task {
      let response = await handler.handle(decoded, file: file) { completed, total in
        // A report that cannot be delivered is dropped: it never fails the transfer.
        reported.mark()
        client?.progress(id, completed: completed, total: total)
      }
      if reported.any, let connection {
        await Self.flush(id, on: connection)
      }
      reply(Self.encode(response))
    }
  }

  /// Waits until the client has every report sent before now, or its connection fails.
  private static func flush(_ id: String, on connection: NSXPCConnection) async {
    _ = await awaitReply { reply, failed in
      guard let client = connection.remoteObjectProxyWithErrorHandler(failed) as? any AgentClientXPC
      else {
        failed(CancellationError())
        return
      }
      client.flush(id) { reply(Data()) }
    }
  }

  private static func encode(_ response: AgentResponse) -> Data {
    do {
      return try JSONEncoder().encode(response)
    } catch {
      // Only a non-finite date could fail here. The client reads an empty reply as a bad
      // response rather than waiting for one that never comes.
      log.fault("cannot encode response: \(error, privacy: .public)")
      return Data()
    }
  }
}
