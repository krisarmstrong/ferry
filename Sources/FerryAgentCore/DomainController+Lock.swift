import DeviceKit

// MARK: Requests refused while the device was locked

extension DomainController {
  /// A request on `domain` failed because its device was locked, which FileProvider takes as
  /// sign-in needed: it holds that domain's work until told the cause is gone.
  func noteRefusedAsLocked(_ domain: String) {
    refusedAsLocked.insert(domain)
  }

  /// The device of `domain` answers again: FileProvider is told, if it was holding the domain's
  /// work because the device was locked.
  func resolveLockRefusal(_ domain: String) async {
    guard refusedAsLocked.remove(domain) != nil else { return }
    await manager.lockResolved(domain)
  }
}
