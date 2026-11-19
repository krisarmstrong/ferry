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
    #expect(model.actionError == "Ferry was updated. Quit and reopen Ferry.")
    #expect(model.agent == .replaced)
    #expect(!log.all.contains("quit"))
  }

  @Test func removeFerryFromAnUnchangedAppSaysToCheckFerryRuns() async {
    let model = AppModel(client: UnreachableClient(), services: FakeServices(log: log))
    await model.removeFerry()
    #expect(
      model.actionError == "Could not remove Ferry. Make sure Ferry is running, then try again.")
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
}
