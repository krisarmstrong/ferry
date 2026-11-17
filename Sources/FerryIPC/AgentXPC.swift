import DeviceKit
import Foundation
import os

/// The agent's XPC interface. Requests and replies are JSON-encoded `AgentRequest` and
/// `AgentResponse`, so the wire format is ordinary `Codable` rather than `NSSecureCoding`.
@objc public protocol AgentXPC {
  func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

/// Serves agent requests from the app and the FileProvider extension.
public protocol AgentHandling: Sendable {
  func handle(_ request: AgentRequest) async -> AgentResponse
}

/// Accepts connections on the agent's listener and routes their requests to a handler.
public final class AgentListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
  /// Admits only the Ferry app and its FileProvider extension, signed by the Ferry team.
  public static let ferryClientRequirement = """
    anchor apple generic and certificate leaf[subject.OU] = "X6JWYP43HG" and \
    (identifier "io.github.krisarmstrong.ferry" or \
    identifier "io.github.krisarmstrong.ferry.provider")
    """

  private let handler: any AgentHandling
  private let codeSigningRequirement: String?

  /// `codeSigningRequirement` is checked on every message; nil admits any peer, which only an
  /// anonymous listener in tests may use.
  public init(
    handler: any AgentHandling, codeSigningRequirement: String? = ferryClientRequirement
  ) {
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

  func send(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
    let decoded: AgentRequest
    do {
      decoded = try JSONDecoder().decode(AgentRequest.self, from: request)
    } catch {
      Self.log.error("rejected undecodable request: \(error, privacy: .private)")
      reply(Self.encode(.failure(.io("bad request"))))
      return
    }
    Task {
      reply(Self.encode(await handler.handle(decoded)))
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
