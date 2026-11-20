import Foundation
import Testing

@testable import PlatformTools

/// The real check, on files that must fail it. The one that passes is Google's adb, which the
/// repository must not carry: the live check script covers it.
struct CodeSignatureTests {
  @Test func appleSignedIsNotGoogle() {
    #expect(throws: PlatformToolsError.notSigned) {
      try CodeSignature.checkGoogle(URL(filePath: "/bin/ls"))
    }
  }

  /// The same check passes with Apple's own requirement, so the failure above is the team.
  @Test func theCheckReadsTheSignature() throws {
    try CodeSignature.check(URL(filePath: "/bin/ls"), requirement: "anchor apple")
  }

  @Test func anUnsignedFileIsNotGoogle() throws {
    let file = FileManager.default.temporaryDirectory.appending(path: "ferry-unsigned-\(UUID())")
    try Data("#!/bin/sh\n".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(throws: PlatformToolsError.notSigned) { try CodeSignature.checkGoogle(file) }
  }

  @Test func aMissingFileIsNotGoogle() {
    #expect(throws: PlatformToolsError.notSigned) {
      try CodeSignature.checkGoogle(URL(filePath: "/nonexistent/adb"))
    }
  }

  @Test func theRequirementNamesGooglesTeam() {
    #expect(CodeSignature.googleTeamID == "EQHXZ8M8AV")
    #expect(
      CodeSignature.googleRequirement.contains("certificate leaf[subject.OU] = \"EQHXZ8M8AV\""))
    #expect(CodeSignature.googleRequirement.contains("identifier \"adb\""))
  }
}
