import DeviceKit
import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// The calls the extension makes from FileProvider's callbacks: its arguments are not Sendable,
/// so only snapshots of them may cross into a task.
struct ShellShapeTests {
  @Test func templateIsSendableSnapshot() async throws {
    let agent = FakeAgent([try folder("/Docs")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let docs = try await agent.identifier(try path("/Docs"))
    let item: any NSFileProviderItem = Template(parent: docs, filename: "Sub", contentType: .folder)

    // The extension's callback shape: snapshot synchronously, then hand only Sendable values to
    // the task.
    let template = try ItemTemplate(item)
    let made = try await Task { try await backend.create(template, contents: nil) }.value

    #expect(
      template == ItemTemplate(parent: try #require(ItemID(docs)), filename: "Sub", kind: .folder))
    #expect(made.parentItemIdentifier == docs)
    #expect(try ItemTemplate(Template(parent: .rootContainer, filename: "f")).parent == .root)
    #expect(throws: NSFileProviderError(.noSuchItem)) {
      try ItemTemplate(Template(parent: .trashContainer, filename: "f"))
    }
  }

  /// The extension's modify callback shape, with FileProvider's arguments arriving as parameters:
  /// only the snapshots cross into the task.
  private func shellModify(
    _ backend: ProviderBackend, _ item: any NSFileProviderItem, _ fields: NSFileProviderItemFields,
    _ url: URL?
  ) throws -> Task<ProviderItem, any Error> {
    let id = item.itemIdentifier
    let template = try ItemTemplate(item)
    let changes = ItemChanges(fields)
    return Task { try await backend.modify(id, to: template, changed: changes, contents: url) }
  }

  @Test func shellShapedModifyKeepsIdentifier() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.identifier(try path("/a.txt"))
    let item = Template(id: id.rawValue, parent: .rootContainer, filename: "b.txt")

    let renamed = try await shellModify(backend, item, [.filename], nil).value

    #expect(renamed.itemIdentifier == id)
    #expect(renamed.filename == "b.txt")
  }

  // FileProvider aborts the extension on an item with an empty filename.
  @Test func rootItemHasNonEmptyFilename() async throws {
    let agent = FakeAgent([try folder("/DCIM")])
    let backend = ProviderBackend(domain: domain, client: agent)

    let root = try await backend.item(.rootContainer)
    #expect(root.itemIdentifier == .rootContainer)
    #expect(!root.filename.isEmpty)
    for child in try await backend.children(of: .rootContainer) {
      #expect(!child.filename.isEmpty)
    }
  }
}
