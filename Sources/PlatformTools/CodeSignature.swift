import Foundation
import Security

/// Checks that a file is signed by Google before Ferry runs it.
public enum CodeSignature {
  /// Google LLC's Developer ID team, which signs the platform tools' `adb`.
  public static let googleTeamID = "EQHXZ8M8AV"

  /// The designated requirement of Google's `adb` (`codesign -d -r-`): a Developer ID
  /// Application certificate issued to Google's team, for the identifier `adb`.
  static let googleRequirement = """
    identifier "adb" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] \
    and certificate leaf[field.1.2.840.113635.100.6.1.13] \
    and certificate leaf[subject.OU] = "\(googleTeamID)"
    """

  /// Throws `.notSigned` unless every architecture of `file` carries a valid signature by
  /// Google's team for `adb`.
  public static func checkGoogle(_ file: URL) throws(PlatformToolsError) {
    try check(file, requirement: googleRequirement)
  }

  /// Every architecture, strictly, nested code included, and never over the network: the check
  /// runs offline, as often as the agent looks for adb, and never asks Apple about revocation.
  static let flags = SecCSFlags(
    rawValue: SecCSFlags.RawValue(
      kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
  ).union(.noNetworkAccess)

  /// `checkGoogle`, remembered for a file until it changes on disk.
  static let googleSigned = VerifiedFiles(check: checkGoogle)

  /// Whether `file` is Google's, checking it again only if it changed since it last passed.
  public static func isGoogleSigned(_ file: URL) -> Bool {
    (try? googleSigned.check(file)) != nil
  }

  /// What `codesign --verify --strict -R=<requirement>` checks, without running a process.
  static func check(_ file: URL, requirement text: String) throws(PlatformToolsError) {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw .notSigned }
    guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
      throw .notSigned
    }
  }
}
