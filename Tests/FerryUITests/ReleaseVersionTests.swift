import Foundation
import Testing

/// release-please sets the version in project.yml. Sparkle offers an update only when the new
/// CFBundleVersion is newer, so the build number moves with the version, on every release.
struct ReleaseVersionTests {
  private static let root = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

  private static func text(_ path: String) throws -> String {
    try String(contentsOf: root.appending(path: path), encoding: .utf8)
  }

  private static func json(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appending(path: path))
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// The version on the one project.yml line `setting:` names, which release-please must mark.
  private static func version(of setting: String) throws -> String {
    let lines = try text("project.yml").split(separator: "\n")
    let line = try #require(lines.first { $0.contains("\(setting):") }, "\(setting)")
    let match = try #require(
      line.wholeMatch(of: /\s*\w+: "(\d+\.\d+\.\d+)" # x-release-please-version/), "\(line)")
    return String(match.1)
  }

  @Test func theBuildNumberIsTheVersion() throws {
    #expect(
      try Self.version(of: "CURRENT_PROJECT_VERSION") == Self.version(of: "MARKETING_VERSION"))
  }

  @Test func theManifestHasTheProjectsVersion() throws {
    let manifest = try Self.json(".release-please-manifest.json")
    #expect(manifest["."] as? String == (try Self.version(of: "MARKETING_VERSION")))
  }

  /// Before 1.0 a feature is a minor release and a fix a patch; a breaking change stays below
  /// 1.0 until the owner declares it.
  @Test func releasePleaseUpdatesTheProjectAndStaysBelowOne() throws {
    let config = try Self.json("release-please-config.json")
    #expect(config["bump-minor-pre-major"] as? Bool == true)
    #expect(config["bump-patch-for-minor-pre-major"] as? Bool == false)
    let packages = try #require(config["packages"] as? [String: Any])
    let package = try #require(packages["."] as? [String: Any])
    #expect(package["release-type"] as? String == "simple")
    #expect(package["changelog-path"] as? String == "CHANGELOG.md")
    #expect((package["extra-files"] as? [String])?.contains("project.yml") == true)
  }
}
