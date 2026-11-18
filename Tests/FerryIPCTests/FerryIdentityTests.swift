import DeviceKitTestSupport
import Foundation
import Testing

@testable import FerryIPC

/// Everything team-specific is built from the one team ID the build sets.
struct FerryIdentityTests {
  @Test func identifiersComeFromTheTeamID() throws {
    let identity = try #require(FerryIdentity(teamID: "ABCDE12345"))
    #expect(identity.machServiceName == "ABCDE12345.io.github.krisarmstrong.ferry.agent")
    #expect(identity.appGroup == "ABCDE12345.io.github.krisarmstrong.ferry")
    #expect(
      identity.clientRequirement == """
        anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and \
        (identifier "io.github.krisarmstrong.ferry" or \
        identifier "io.github.krisarmstrong.ferry.provider")
        """)
    #expect(
      identity.agentRequirement == """
        anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and \
        identifier "io.github.krisarmstrong.ferry.agent"
        """)
  }

  /// A team ID is ten upper-case letters or digits; anything else (an unexpanded build setting,
  /// an injection into the requirement) is refused.
  @Test(arguments: ["", "$(FERRY_TEAM_ID)", "abcde12345", "ABCDE1234", "ABCDE\" or 1"])
  func malformedTeamIDIsRefused(_ teamID: String) {
    #expect(FerryIdentity(teamID: teamID) == nil)
  }

  @Test func teamIDIsReadFromTheInfoPlist() throws {
    let bundleURL = TestScratch.root.appending(
      path: "Identity-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
    let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let plist: [String: Any] = ["CFBundleIdentifier": "test.identity", "FerryTeamID": "ABCDE12345"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
    let bundle = try #require(Bundle(url: bundleURL))

    #expect(FerryIdentity(bundle: bundle)?.teamID == "ABCDE12345")
  }

  /// A build that did not record the team has no identity, so the process stops at launch
  /// rather than naming a service nobody registered.
  @Test func aBundleWithoutTheTeamHasNoIdentity() throws {
    let bundleURL = TestScratch.root.appending(
      path: "Identity-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
    let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: bundleURL) }
    let plist: [String: Any] = ["CFBundleIdentifier": "test.identity"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
      .write(to: contents.appending(path: "Info.plist"))
    let bundle = try #require(Bundle(url: bundleURL))

    #expect(FerryIdentity(bundle: bundle) == nil)
  }
}
