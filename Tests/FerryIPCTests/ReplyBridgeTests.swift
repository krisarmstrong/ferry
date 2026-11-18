import Foundation
import Testing

@testable import FerryIPC

private struct Lost: Error {}

@Test func replyThenErrorResumesOnceWithReply() async throws {
  let result = await awaitReply { reply, failed in
    reply(Data([1]))
    failed(Lost())
  }
  #expect(try result.get() == Data([1]))
}

@Test func errorThenReplyResumesOnceWithError() async {
  let result = await awaitReply { reply, failed in
    failed(Lost())
    reply(Data([1]))
  }
  #expect(throws: Lost.self) { try result.get() }
}

@Test func concurrentReplyAndErrorResumeOnce() async {
  for _ in 0..<200 {
    let result = await awaitReply { reply, failed in
      Task.detached { reply(Data([1])) }
      Task.detached { failed(Lost()) }
    }
    switch result {
    case .success(let data): #expect(data == Data([1]))
    case .failure(let error): #expect(error is Lost)
    }
  }
}

@Test(.timeLimit(.minutes(1))) func cancellationReturnsWithoutAReply() async {
  let call = Task {
    await awaitReply { _, _ in }
  }
  call.cancel()
  let result = await call.value
  #expect(throws: CancellationError.self) { try result.get() }
}
