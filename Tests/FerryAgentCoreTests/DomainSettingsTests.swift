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
}
