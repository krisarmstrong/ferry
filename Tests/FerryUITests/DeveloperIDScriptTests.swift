import Foundation
import Testing

/// scripts/check-developer-id.sh, which the release's import step runs on the opened .p12,
/// against certificates made here with openssl.
struct DeveloperIDScriptTests {
  /// A self-signed certificate named `name`, with its private key, as `openssl pkcs12 -nodes`
  /// writes an identity.
  static func identity(_ name: String, in folder: URL) throws -> String {
    let key = folder.appending(path: "key-\(UUID().uuidString).pem")
    let cert = folder.appending(path: "cert-\(UUID().uuidString).pem")
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/openssl")
    process.arguments = [
      "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key.path,
      "-out", cert.path, "-subj", "/CN=\(name)/OU=X6JWYP43HG/O=Test/C=US",
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    return try String(contentsOf: key, encoding: .utf8) + String(contentsOf: cert, encoding: .utf8)
  }

  /// The team the release signs as (project.yml's FERRY_TEAM_ID).
  static let team = "X6JWYP43HG"

  static func checkIdentity(_ names: [String], extra: String = "") async throws -> (
    ReleaseScriptTests.Outcome, pem: String
  ) {
    try await ReleaseScriptTests.offThePool { try checkIdentitySync(names, extra: extra) }
  }

  private static func checkIdentitySync(_ names: [String], extra: String) throws -> (
    ReleaseScriptTests.Outcome, pem: String
  ) {
    let folder = FileManager.default.temporaryDirectory
      .appending(path: "developer-id-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let pem = try names.map { try identity($0, in: folder) }.joined() + extra
    let file = folder.appending(path: "identity.pem")
    try pem.write(to: file, atomically: true, encoding: .utf8)
    return (try ReleaseScriptTests.run("scripts/check-developer-id.sh", [file.path, team]), pem)
  }

  @Test func aDeveloperIDApplicationIdentityPasses() async throws {
    let (result, _) = try await Self.checkIdentity([
      "Developer ID Application: Test, Person (X6JWYP43HG)"
    ])
    #expect(result.status == 0)
    #expect(result.output.contains("Developer ID Application: Test, Person (X6JWYP43HG)"))
  }

  /// The .p12 exported from the wrong certificate: the error says which one it was.
  @Test func anInstallerIdentityIsNamedInTheError() async throws {
    let (result, _) = try await Self.checkIdentity([
      "Developer ID Installer: Test, Person (X6JWYP43HG)"
    ]
    )
    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "certificate of team X6JWYP43HG, only \"Developer ID Installer: Test, Person (X6JWYP43HG)\""
      ))
  }

  /// Only names are printed: no line of the key or the certificate reaches the log.
  @Test func nothingButNamesIsPrinted() async throws {
    let (result, pem) = try await Self.checkIdentity([
      "Developer ID Installer: Test (X6JWYP43HG)", "Apple Development: Test (X6JWYP43HG)",
    ])
    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "\"Developer ID Installer: Test (X6JWYP43HG)\", \"Apple Development: Test (X6JWYP43HG)\""))
    let material = pem.split(separator: "\n").filter { !$0.hasPrefix("-----") }
    #expect(!material.isEmpty)
    #expect(material.allSatisfy { !result.output.contains($0) })
    #expect(!result.output.contains("PRIVATE KEY"))
  }

  /// A Developer ID Application certificate of another team fails here, not in Build and sign.
  @Test func anotherTeamsIdentityFails() async throws {
    let (result, _) = try await Self.checkIdentity([
      "Developer ID Application: Someone Else (ABCDE12345)"
    ])
    #expect(result.status != 0)
    #expect(
      result.output.contains(
        "certificate of team X6JWYP43HG, only "
          + "\"Developer ID Application: Someone Else (ABCDE12345)\""
      ))
  }

  /// A certificate block openssl cannot read is named as such, not a silent exit.
  @Test func aMalformedCertificateIsReported() async throws {
    let garbage =
      "-----BEGIN CERTIFICATE-----\nbm90IGEgY2VydGlmaWNhdGU=\n-----END CERTIFICATE-----\n"
    let (result, _) = try await Self.checkIdentity([], extra: garbage)
    #expect(result.status != 0)
    #expect(
      result.output.contains("::error::certificate 1 in DEVELOPER_ID_P12_BASE64 cannot be read"))
  }

  @Test func aFileWithoutCertificatesFails() async throws {
    let (result, _) = try await Self.checkIdentity([])
    #expect(result.status != 0)
    #expect(result.output.contains("holds no certificate"))
  }
}
