import DeviceKit
import Foundation
import Testing

@testable import FerryIPC

/// The Finder Sync extension lists devices, sends files and installs apps, and nothing else: a
/// compromised extension cannot touch items, eject devices or change what this Mac connects to.
@Test func theFinderExtensionMaySendOnlyItsThreeRequests() {
  for request in requests() {
    let expected: Bool
    switch request {
    case .status, .sendFile, .installAPK: expected = true
    default: expected = false
    }
    #expect(ClientRole.finderSync.allows(request) == expected, "\(request)")
  }
}

/// Sending a file is the extension's alone: the app and the FileProvider extension copy files
/// through Finder's location instead.
@Test func onlyTheFinderExtensionSendsFiles() {
  let request = AgentRequest.sendFile(DeviceID(serial: "A"), name: "Report.pdf")
  #expect(ClientRole.finderSync.allows(request))
  #expect(!ClientRole.app.allows(request))
  #expect(!ClientRole.provider.allows(request))
}

@Test func theFinderExtensionHasItsOwnRequirement() throws {
  let identity = try #require(FerryIdentity(teamID: "ABCDE12345"))
  #expect(
    identity.requirement(for: .finderSync) == """
      anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and \
      identifier "io.github.krisarmstrong.ferry.sync"
      """)
}

/// A file goes to the device by name only: the agent gets its contents as a descriptor.
@Test func aSentFileTravelsByNameOnly() throws {
  let request = AgentRequest.sendFile(DeviceID(serial: "A"), name: "Report.pdf")
  let json = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
  #expect(!json.contains("/"))
  #expect(try JSONDecoder().decode(AgentRequest.self, from: Data(json.utf8)) == request)
}
