import Foundation

/// The identifiers that depend on the team signing Ferry, built from its team ID.
///
/// The build sets the team once (`FERRY_TEAM_ID`, see the README), and every bundle carries it
/// as `FerryTeamID` in its Info.plist, so no team is spelled out in code. The app group, the
/// agent's Mach service name (which must start with the team ID) and the code-signing
/// requirements of both ends of the XPC connection all come from it.
public struct FerryIdentity: Sendable, Equatable {
  public let teamID: String

  /// `nil` unless `teamID` is ten upper-case letters or digits, as Apple team IDs are. That also
  /// keeps anything but a team ID out of the requirements.
  public init?(teamID: String) {
    let valid =
      teamID.utf8.count == 10
      && teamID.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    guard valid else { return nil }
    self.teamID = teamID
  }

  /// The team the build recorded in `bundle`'s Info.plist.
  public init?(bundle: Bundle = .main) {
    guard let teamID = bundle.object(forInfoDictionaryKey: "FerryTeamID") as? String else {
      return nil
    }
    self.init(teamID: teamID)
  }

  public var appGroup: String { "\(teamID).io.github.krisarmstrong.ferry" }

  public var machServiceName: String { "\(teamID).io.github.krisarmstrong.ferry.agent" }

  /// Admits only the Ferry app and its FileProvider extension, signed by this team.
  public var clientRequirement: String {
    """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \
    (identifier "io.github.krisarmstrong.ferry" or \
    identifier "io.github.krisarmstrong.ferry.provider")
    """
  }

  /// Admits only the client in `role`, signed by this team.
  public func requirement(for role: ClientRole) -> String {
    """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \
    identifier "\(role.signingIdentifier)"
    """
  }

  /// The agent itself, as its clients require it to be signed.
  public var agentRequirement: String {
    """
    anchor apple generic and certificate leaf[subject.OU] = "\(teamID)" and \
    identifier "io.github.krisarmstrong.ferry.agent"
    """
  }
}

/// Which Ferry process a connection to the agent comes from. Each may send only the requests it
/// needs: the app manages devices and domains, the FileProvider extension works on items.
public enum ClientRole: Sendable, CaseIterable {
  case app
  case provider

  var signingIdentifier: String {
    switch self {
    case .app: "io.github.krisarmstrong.ferry"
    case .provider: "io.github.krisarmstrong.ferry.provider"
    }
  }

  /// Whether a client in this role may send `request`.
  public func allows(_ request: AgentRequest) -> Bool {
    switch request {
    case .status, .recheck, .recheckADB, .refresh, .eject, .removeAllDomains, .connectAddress,
      .pair, .connectWireless, .enableWireless, .forgetWireless, .confirmWireless, .ignoreWireless,
      .installAPK, .screenshot, .startRecording, .stopRecording, .saveRecording, .discardRecording,
      .startLogcat, .stopLogcat, .forwards, .addForward, .removeForward, .deviceInfo, .shellTarget:
      self == .app
    case .item, .list, .fetch, .create, .rename, .move, .replaceContents, .delete, .changes,
      .workingSet:
      self == .provider
    }
  }
}
