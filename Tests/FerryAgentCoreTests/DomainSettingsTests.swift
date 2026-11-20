import DeviceKit
import FileProvider
import Testing

@testable import FerryAgentCore

struct DomainSettingsTests {
  let identifier = DomainNaming.identifier(
    for: StorageID(device: DeviceID(serial: "0123456789abcdef"), key: "internal"))

  @Test func aDomainFerryAddsHasFerrysSettings() {
    let domain = DomainSettings.configured(identifier, displayName: "LinkRunner-100G")
    #expect(domain.identifier.rawValue == identifier)
    #expect(domain.displayName == "LinkRunner-100G")
    #expect(DomainSettings(of: domain) == .ferry)
    #expect(!DomainSettings.needsUpdate(domain))
  }

  /// An earlier Ferry's domain is updated if any setting Ferry gives differs.
  @Test func aDomainLackingASettingIsUpdated() {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier(identifier), displayName: "LinkRunner-100G")
    domain.supportsSyncingTrash = !DomainSettings.ferry.supportsSyncingTrash
    #expect(DomainSettings.needsUpdate(domain))
  }

  /// A domain named by serial is left to `DomainController`, which replaces it.
  @Test func aDomainNamedBySerialIsLeftAlone() {
    let domain = NSFileProviderDomain(
      identifier: NSFileProviderDomainIdentifier("0123456789abcdef"), displayName: "Old")
    domain.supportsSyncingTrash = true
    #expect(!DomainSettings.needsUpdate(domain))
  }

  /// Hiding re-adds the domain under the same identifier with the same settings: per
  /// `NSFileProviderManager.h`, an add for an existing identifier updates only its display name
  /// and hidden state, so the domain's replicated files stay.
  @Test func aHiddenDomainKeepsItsIdentityAndSettings() {
    let domain = DomainSettings.configured(identifier, displayName: "LinkRunner-100G", hidden: true)
    #expect(domain.isHidden)
    #expect(domain.identifier.rawValue == identifier)
    #expect(domain.displayName == "LinkRunner-100G")
    #expect(DomainSettings(of: domain) == .ferry)
    #expect(!DomainSettings.configured(identifier, displayName: "LinkRunner-100G").isHidden)
  }

  /// Being hidden is not a setting: a hidden domain with Ferry's settings is not added again at
  /// start, which would show it.
  @Test func aHiddenDomainNeedsNoUpdate() {
    let domain = DomainSettings.configured(identifier, displayName: "LinkRunner-100G", hidden: true)
    #expect(!DomainSettings.needsUpdate(domain))
  }
}
