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

  /// What `codesign --verify --strict -R=<requirement>` checks, without running a process.
  static func check(_ file: URL, requirement text: String) throws(PlatformToolsError) {
    var code: SecStaticCode?
    var requirement: SecRequirement?
    guard SecStaticCodeCreateWithPath(file as CFURL, [], &code) == errSecSuccess, let code,
      SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
      let requirement
    else { throw .notSigned }
    let flags = SecCSFlags(
      rawValue: SecCSFlags.RawValue(
        kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
    guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
      throw .notSigned
    }
  }
}
