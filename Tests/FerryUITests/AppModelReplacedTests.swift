import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// An app whose bundle was replaced while it ran (an update) is refused by the new agent: the
/// menu says to reopen Ferry and offers Relaunch, rather than saying Ferry is not running.
@MainActor
struct AppModelReplacedTests {
  let log = CallLog()

  @Test func aReplacedAppThatTheAgentRefusesSaysToReopen() async {
    let services = FakeServices(log: log)
    services.replaced = true
    let model = AppModel(client: UnreachableClient(), services: services)
    await model.refresh()
    #expect(model.agent == .replaced)
  }

  /// The same failure with the app as it launched is the helper not answering.
  @Test func anUnchangedAppThatTheAgentRefusesIsUnreachable() async {
    let model = AppModel(client: UnreachableClient(), services: FakeServices(log: log))
    await model.refresh()
    #expect(model.agent == .unreachable)
  }

  @Test func removeFerryFromAReplacedAppSaysToReopen() async {
    let services = FakeServices(log: log)
    services.replaced = true
    let model = AppModel(client: UnreachableClient(), services: services)
    await model.removeFerry()
    #expect(model.removalError == "Ferry was updated. Quit and reopen Ferry.")
    #expect(model.agent == .replaced)
    #expect(!log.all.contains("quit"))
  }

  /// An unchanged app removes the locations itself when the helper cannot; if that fails too,
  /// it says to try again.
  @Test func removeFerryFromAnUnchangedAppSaysToTryAgain() async {
    let services = FakeServices(log: log)
    services.failRemoveDomains = true
    let model = AppModel(client: UnreachableClient(), services: services)
    await model.removeFerry()
    #expect(
      model.removalError
        == "Could not remove Ferry. Try again; if it keeps failing, restart the Mac and try again.")
  }

  @Test func relaunchOpensFerryAgain() {
    let model = AppModel(client: UnreachableClient(), services: FakeServices(log: log))
    model.relaunch()
    #expect(log.all == ["relaunch"])
  }
}

/// What tells a replaced executable from the one that launched.
struct ExecutableIdentityTests {
  @Test func theSameFileIsTheSameExecutable() throws {
    let file = try TestScratch.folder("identity").appending(path: "Ferry")
    try Data("one".utf8).write(to: file)
    let first = try #require(ExecutableIdentity(of: file))
    #expect(ExecutableIdentity(of: file) == first)
  }

  /// An update copies a new file over the old path (rsync, ditto and the installer each put a
  /// new file there), even one of the same size.
  @Test func aFileReplacedAtThePathIsAnother() throws {
    let folder = try TestScratch.folder("identity")
    let file = folder.appending(path: "Ferry")
    try Data("one".utf8).write(to: file)
    let first = try #require(ExecutableIdentity(of: file))
    let update = folder.appending(path: "Ferry.new")
    try Data("two".utf8).write(to: update)
    #expect(rename(update.path, file.path) == 0)
    #expect(ExecutableIdentity(of: file) != first)
  }

  @Test func aMissingFileHasNoIdentity() throws {
    let folder = try TestScratch.folder("identity")
    #expect(ExecutableIdentity(of: folder.appending(path: "gone")) == nil)
  }

  /// An update that changes only the agent or a resource leaves the app's executable alone but
  /// changes the bundle's seal, and the new agent refuses the app all the same.
  @Test func aBundleWhoseSealChangedIsAnother() throws {
    let folder = try TestScratch.folder("identity")
    let executable = folder.appending(path: "Ferry")
    let seal = folder.appending(path: "CodeResources")
    try Data("app".utf8).write(to: executable)
    try Data("seal one".utf8).write(to: seal)
    let launched = BundleFingerprint(of: [executable, seal])
    #expect(BundleFingerprint(of: [executable, seal]) == launched)
    let update = folder.appending(path: "CodeResources.new")
    try Data("seal two".utf8).write(to: update)
    #expect(rename(update.path, seal.path) == 0)
    #expect(BundleFingerprint(of: [executable, seal]) != launched)
  }
}
