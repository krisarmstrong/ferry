import FerryIPC
import FerryProviderCore
import FileProvider
import Foundation
import Testing

/// FileProvider cancels an operation by cancelling its progress, which cancels the task running
/// the backend call: the call must end promptly and leave nothing behind.
struct CancellationTests {
  @Test(.timeLimit(.minutes(1))) func cancelledFetchReturnsPromptlyAndLeavesNoFile()
    async throws
  {
    let agent = FakeAgent(
      [try file("/a.txt", size: 5)], contents: [try path("/a.txt"): Data("hello".utf8)])
    await agent.parkFetchesUntilCancelled()
    let backend = ProviderBackend(domain: domain, client: agent)
    let dir = try scratchDirectory()
    let id = try await agent.identifier(try path("/a.txt"))

    let fetch = Task { try await backend.fetch(id, into: dir) }
    var started = agent.fetchStarted.makeAsyncIterator()
    await started.next()
    fetch.cancel()

    await #expect(throws: CocoaError(.userCancelled)) { try await fetch.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
  }

  @Test func cancelledCallSendsNothing() async throws {
    let agent = FakeAgent([try file("/a.txt")])
    let backend = ProviderBackend(domain: domain, client: agent)
    let id = try await agent.identifier(try path("/a.txt"))

    let call = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await backend.item(id)
    }
    await #expect(throws: CocoaError(.userCancelled)) { try await call.value }
    #expect(await agent.requests.isEmpty)
  }
}
