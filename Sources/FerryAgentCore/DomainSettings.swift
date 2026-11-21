import FileProvider

/// Every setting Ferry gives its FileProvider domains. A domain is added with them, and one the
/// system already has (from an earlier Ferry) is added again when any of them differs, so a
/// change here reaches existing domains. A setting Ferry starts to set belongs here, and is then
/// both applied and compared.
public struct DomainSettings: Equatable, Sendable {
  public var supportsSyncingTrash: Bool

  /// Ferry's settings. Neither MTP nor ADB has a trash: Finder offers Delete Immediately, which
  /// deletes on the device.
  public static let ferry = DomainSettings(supportsSyncingTrash: false)

  /// The settings `domain` has now.
  public init(of domain: NSFileProviderDomain) {
    supportsSyncingTrash = domain.supportsSyncingTrash
  }

  init(supportsSyncingTrash: Bool) {
    self.supportsSyncingTrash = supportsSyncingTrash
  }

  /// A domain with Ferry's settings, hidden from Finder or not. Being hidden is the domain's
  /// state, not a setting: every add of an existing domain carries the state it should keep,
  /// since the add sets it (`NSFileProviderManager.h`, `addDomain:`).
  public static func configured(_ identifier: String, displayName: String, hidden: Bool = false)
    -> NSFileProviderDomain
  {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(identifier), displayName: displayName)
    domain.supportsSyncingTrash = ferry.supportsSyncingTrash
    domain.isHidden = hidden
    return domain
  }

  /// Whether `domain` is one of Ferry's (not one named by serial, which `DomainController`
  /// replaces) and lacks any of Ferry's settings.
  public static func needsUpdate(_ domain: NSFileProviderDomain) -> Bool {
    DomainNaming.isIdentifier(domain.identifier.rawValue) && DomainSettings(of: domain) != ferry
  }
}
