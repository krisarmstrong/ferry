import DeviceKit
import Foundation
import Security
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
///
/// Each connection is tagged with the role of the Ferry process it comes from, and its requests
/// are limited to that role's (see `ClientRole.allows`).
public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
  private let handler: any AgentHandling
  /// The role a new connection's peer has, having set the connection's code-signing
  /// requirement; `nil` refuses the connection. A role of `nil` inside admits a test peer with
  /// every request allowed.
  private let admit: @Sendable (NSXPCConnection) -> ClientRole??

  /// Admits only the Ferry app and its extension signed by `identity`'s team.
  ///
  /// The peer's role is read from its signature, found by process ID, when it connects. That
  /// role's own requirement is then set on the connection and checked by XPC on every message,
  /// so a process ID reused in between can only lose the connection, never gain a role.
  public convenience init(handler: any AgentHandling, identity: FerryIdentity) {
    self.init(handler: handler) { connection in
      guard let role = ClientRole.signed(pid: connection.processIdentifier, by: identity) else {
        return nil
      }
      connection.setCodeSigningRequirement(identity.requirement(for: role))
      return .some(role)
    }
  }

  /// Admits any peer in `role`, or with every request allowed for `nil`, which only an anonymous
  /// listener in tests may use.
  convenience init(handler: any AgentHandling, role: ClientRole?) {
    self.init(handler: handler) { _ in .some(role) }
  }

  private init(
    handler: any AgentHandling, admit: @escaping @Sendable (NSXPCConnection) -> ClientRole??
  ) {
    self.handler = handler
    self.admit = admit
  }

  public func listener(
    _ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection
  ) -> Bool {
    guard let role = admit(connection) else { return false }
    connection.exportedInterface = NSXPCInterface(with: AgentXPC.self)
    connection.exportedObject = AgentService(handler: handler, role: role)
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
  /// `nil` only for a test peer.
  private let role: ClientRole?

  init(handler: any AgentHandling, role: ClientRole?) {
    self.handler = handler
    self.role = role
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
    if let role, !role.allows(decoded) {
      Self.log.error("refused a request its client may not send")
      reply(Self.encode(.failure(.io("request not allowed"))))
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

extension ClientRole {
  /// The role of the process `pid`, if it is the Ferry app or extension signed by `identity`.
  static func signed(pid: pid_t, by identity: FerryIdentity) -> ClientRole? {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid: pid] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
      let code
    else { return nil }
    return allCases.first { role in
      var requirement: SecRequirement?
      guard
        SecRequirementCreateWithString(
          identity.requirement(for: role) as CFString, [], &requirement) == errSecSuccess,
        let requirement
      else { return false }
      return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
  }
}
