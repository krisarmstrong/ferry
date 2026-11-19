import DeviceKit
import DeviceKitTestSupport
import FerryIPC
import Foundation
import Testing

@testable import FerrySyncCore

/// Records what the extension sends: each request, and the bytes its descriptor reads.
private actor RecordingAgent: AgentSending {
  struct Sent: Equatable {
    let request: AgentRequest
    let contents: Data?
  }

  private(set) var sent: [Sent] = []
  private let answer: @Sendable (AgentRequest) -> AgentResponse

  init(answer: @escaping @Sendable (AgentRequest) -> AgentResponse) {
    self.answer = answer
  }

  func send(_ request: AgentRequest, file: FileHandle?, progress: TransferProgressHandler?)
    async throws(TransportError) -> AgentResponse
  {
    // Read from the start, as the agent does: the descriptor's offset proves nothing.
    let contents = file.map { handle in
      var bytes = Data()
      var buffer = [UInt8](repeating: 0, count: 4096)
      var offset: off_t = 0
      while true {
        let count = pread(handle.fileDescriptor, &buffer, buffer.count, offset)
        guard count > 0 else { break }
        bytes.append(contentsOf: buffer[0..<count])
        offset += off_t(count)
      }
      return bytes
    }
    sent.append(Sent(request: request, contents: contents))
    return answer(request)
  }
}

private let device = DeviceID(serial: "A")

private func entry(_ path: String) throws -> AgentResponse {
  .entry(
    ProviderEntry(
      id: .random(), parent: .random(),
      item: RemoteItem(path: try RemotePath(path), kind: .file, size: 1, modified: Date())))
}

private func sentAs(_ name: String) -> @Sendable (AgentRequest) -> AgentResponse {
  { request in
    guard case .sendFile(_, let sent) = request else { return .failure(.io("unexpected")) }
    return (try? entry("/Download/\(sent == "Report.pdf" ? name : sent)")) ?? .done
  }
}

@Suite(.timeLimit(.minutes(1)))
struct FinderSenderTests {
  /// Each file goes as its name and an open descriptor; no path reaches the agent.
  @Test func filesTravelAsDescriptors() async throws {
    let folder = try TestScratch.folder("finder-send")
    let report = folder.appending(path: "Report.pdf")
    let notes = folder.appending(path: "notes.txt")
    try Data("report".utf8).write(to: report)
    try Data("notes".utf8).write(to: notes)
    let agent = RecordingAgent(answer: sentAs("Report.pdf"))

    let notice = await FinderSender(agent: agent).perform(
      .send(device), on: [report, notes], deviceName: "LinkRunner")

    #expect(
      await agent.sent == [
        .init(request: .sendFile(device, name: "Report.pdf"), contents: Data("report".utf8)),
        .init(request: .sendFile(device, name: "notes.txt"), contents: Data("notes".utf8)),
      ])
    #expect(
      notice == FinderNotice(title: "Sent 2 files to LinkRunner", body: "They’re in Download."))
  }

  @Test func oneFileSaysWhereItWent() async throws {
    let folder = try TestScratch.folder("finder-send")
    let report = folder.appending(path: "Report.pdf")
    try Data("report".utf8).write(to: report)

    let plain = await FinderSender(agent: RecordingAgent(answer: sentAs("Report.pdf")))
      .perform(.send(device), on: [report], deviceName: "LinkRunner")
    let renamed = await FinderSender(
      agent: RecordingAgent(answer: sentAs("Report (conflict from Mac).pdf"))
    ).perform(.send(device), on: [report], deviceName: "LinkRunner")

    #expect(
      plain == FinderNotice(title: "Sent “Report.pdf” to LinkRunner", body: "It’s in Download."))
    #expect(
      renamed
        == FinderNotice(
          title: "Sent “Report.pdf” to LinkRunner",
          body:
            "Download already had a file with that name, so it’s there as “Report (conflict from Mac).pdf”."
        ))
  }

  /// Folders, packages and links are refused before anything is sent, with Finder's messages.
  @Test func foldersPackagesAndLinksAreRefused() async throws {
    let folder = try TestScratch.folder("finder-send")
    let plain = folder.appending(path: "Photos", directoryHint: .isDirectory)
    let package = folder.appending(path: "Notes.rtfd", directoryHint: .isDirectory)
    let link = folder.appending(path: "link.txt")
    let target = folder.appending(path: "target.txt")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
    try Data("t".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let agent = RecordingAgent(answer: sentAs("Report.pdf"))
    let sender = FinderSender(agent: agent)

    let refusals = [
      await sender.perform(.send(device), on: [plain], deviceName: "LinkRunner"),
      await sender.perform(.send(device), on: [package], deviceName: "LinkRunner"),
      await sender.perform(.send(device), on: [link], deviceName: "LinkRunner"),
    ]

    #expect(await agent.sent.isEmpty)
    #expect(
      refusals.map(\.body) == [
        "Folders can’t be sent from this menu. Copy the folder into the device’s location in "
          + "Finder, or compress it into a .zip first.",
        "Packages and app bundles can’t be copied to the device. Compress it into a .zip first.",
        "Symbolic links and aliases can’t be copied to the device.",
      ])
    #expect(refusals[1].title == "Couldn’t send “Notes.rtfd” to LinkRunner")
  }

  @Test func anAliasIsALink() throws {
    let folder = try TestScratch.folder("finder-send")
    let target = folder.appending(path: "target.txt")
    let alias = folder.appending(path: "target alias")
    try Data("t".utf8).write(to: target)
    let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile)
    try URL.writeBookmarkData(bookmark, to: alias)

    #expect(LocalItem.refusal(for: alias) == .link)
    #expect(LocalItem.refusal(for: target) == nil)
  }

  /// The good files of a mixed selection still go; the notice counts both.
  @Test func aMixedSelectionSendsTheFilesAndReportsTheRest() async throws {
    let folder = try TestScratch.folder("finder-send")
    let report = folder.appending(path: "Report.pdf")
    let photos = folder.appending(path: "Photos", directoryHint: .isDirectory)
    try Data("report".utf8).write(to: report)
    try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
    let agent = RecordingAgent(answer: sentAs("Report.pdf"))

    let notice = await FinderSender(agent: agent).perform(
      .send(device), on: [report, photos], deviceName: "LinkRunner")

    #expect(await agent.sent.map(\.request) == [.sendFile(device, name: "Report.pdf")])
    #expect(notice.title == "Sent 1 of 2 to LinkRunner")
    #expect(
      notice.body
        == "“Photos” wasn’t sent. Folders can’t be sent from this menu. Copy the folder into the device’s "
        + "location in Finder, or compress it into a .zip first.")
  }

  @Test func aFailureSaysWhy() async throws {
    let folder = try TestScratch.folder("finder-send")
    let report = folder.appending(path: "Report.pdf")
    try Data("report".utf8).write(to: report)
    let agent = RecordingAgent { _ in .failure(.insufficientSpace(needed: 10, free: 5)) }

    let notice = await FinderSender(agent: agent).perform(
      .send(device), on: [report], deviceName: "LinkRunner")

    #expect(notice.title == "Couldn’t send “Report.pdf” to LinkRunner")
    #expect(notice.body == "The device doesn’t have enough free space.")
  }

  /// Install goes through the app's own install request, with the app as a descriptor.
  @Test func installSendsTheAppAsADescriptor() async throws {
    let folder = try TestScratch.folder("finder-send")
    let apk = folder.appending(path: "Tester.apk")
    try Data("PK".utf8).write(to: apk)
    let agent = RecordingAgent { _ in .done }

    let notice = await FinderSender(agent: agent).perform(
      .install(device), on: [apk], deviceName: "LinkRunner")

    #expect(
      await agent.sent == [
        .init(request: .installAPK(device, name: "Tester.apk"), contents: Data("PK".utf8))
      ])
    #expect(notice == FinderNotice(title: "Installed “Tester.apk” on LinkRunner", body: ""))
  }

  @Test func aRefusedInstallSaysWhy() async throws {
    let folder = try TestScratch.folder("finder-send")
    let apk = folder.appending(path: "Tester.apk")
    try Data("PK".utf8).write(to: apk)
    let agent = RecordingAgent { _ in .toolFailed(.notAnAPK) }

    let notice = await FinderSender(agent: agent).perform(
      .install(device), on: [apk], deviceName: "LinkRunner")

    #expect(notice.title == "Couldn’t install “Tester.apk” on LinkRunner")
    #expect(notice.body == "That file isn't an Android app (.apk).")
  }

  /// Several failures: the notice names the first and counts the rest.
  @Test func moreFailuresAreCounted() async throws {
    let folder = try TestScratch.folder("finder-send")
    var urls: [URL] = []
    for name in ["a", "b", "c"] {
      let url = folder.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
      urls.append(url)
    }
    let report = folder.appending(path: "Report.pdf")
    try Data("report".utf8).write(to: report)

    let notice = await FinderSender(agent: RecordingAgent(answer: sentAs("Report.pdf")))
      .perform(.send(device), on: [report] + urls, deviceName: "LinkRunner")

    #expect(notice.title == "Sent 1 of 4 to LinkRunner")
    #expect(notice.body.hasPrefix("“a” wasn’t sent. Folders can’t be sent"))
    #expect(notice.body.hasSuffix(" Also not sent: 2."))
  }

  /// A file named Download on the device is in the way.
  @Test func aFileNamedDownloadIsExplained() async throws {
    let folder = try TestScratch.folder("finder-send")
    let report = folder.appending(path: "Report.pdf")
    try Data("report".utf8).write(to: report)
    let blocked = try RemotePath("/Download")
    let agent = RecordingAgent { _ in .failure(.alreadyExists(blocked)) }

    let notice = await FinderSender(agent: agent).perform(
      .send(device), on: [report], deviceName: "LinkRunner")

    #expect(
      notice.body
        == "The device has a file named Download where its Download folder should be. Rename or "
        + "remove it on the device, then try again.")
  }

  /// A file removed between the menu and the action is reported, not sent.
  @Test func aMissingFileIsReported() async throws {
    let folder = try TestScratch.folder("finder-send")
    let agent = RecordingAgent(answer: sentAs("gone.txt"))

    let notice = await FinderSender(agent: agent).perform(
      .send(device), on: [folder.appending(path: "gone.txt")], deviceName: "LinkRunner")

    #expect(await agent.sent.isEmpty)
    #expect(notice.title == "Couldn’t send “gone.txt” to LinkRunner")
  }
}

/// The guards at open time catch an item swapped after it was inspected, which `LocalItem` never
/// sees: each is tested on its own, without the inspection in front of it.
@Suite(.timeLimit(.minutes(1)))
struct FinderOpenTests {
  @Test func aRegularFileOpens() throws {
    let folder = try TestScratch.folder("finder-open")
    let file = folder.appending(path: "a.txt")
    try Data("a".utf8).write(to: file)
    let handle = try FinderSender.openForSending(file).get()
    #expect(try handle.readToEnd() == Data("a".utf8))
  }

  @Test func aSymbolicLinkIsRefused() throws {
    let folder = try TestScratch.folder("finder-open")
    let target = folder.appending(path: "target.txt")
    let link = folder.appending(path: "link.txt")
    try Data("t".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(refusal(FinderSender.openForSending(link)) == .link)
  }

  @Test func aFolderIsRefused() throws {
    let folder = try TestScratch.folder("finder-open")
    #expect(refusal(FinderSender.openForSending(folder)) == .folder)
  }

  /// A FIFO with no writer would block a plain open forever.
  @Test func aFIFOIsRefusedWithoutBlocking() throws {
    let folder = try TestScratch.folder("finder-open")
    let fifo = folder.appending(path: "pipe")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(refusal(FinderSender.openForSending(fifo)) == .notAFile)
  }

  private func refusal(_ result: Result<FileHandle, FinderSender.OpenFailure>)
    -> LocalItem.Refusal?
  {
    if case .failure(let failure) = result { return failure.refusal }
    return nil
  }
}
