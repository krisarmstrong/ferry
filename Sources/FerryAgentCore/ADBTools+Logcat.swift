import ADBTransport
import DeviceKit
import FerryIPC
import Foundation

/// The lines between the device and the client, bounded: the newest `maxLines` lines and
/// `maxBytes` bytes are kept, older ones are dropped and counted, so a client that reads slowly
/// never makes the agent hold the log. One reader takes batches while one writer pushes.
actor LogQueue {
  private let maxLines: Int
  private let maxBytes: Int
  private var lines: [Data] = []
  private var head = 0
  private var bytes = 0
  private var skipped = 0
  private var finished = false
  private(set) var failure: ADBError?
  private var waiter: CheckedContinuation<Void, Never>?

  init(maxLines: Int, maxBytes: Int) {
    self.maxLines = maxLines
    self.maxBytes = maxBytes
  }

  func push(_ chunk: [Data]) {
    for line in chunk {
      lines.append(line)
      bytes += line.count
    }
    // The newest line always stays, however large.
    while lines.count - head > 1, lines.count - head > maxLines || bytes > maxBytes {
      bytes -= lines[head].count
      head += 1
      skipped += 1
    }
    compact()
    wake()
  }

  /// No more lines come: `failure` is why, or `nil` when the device ended the log.
  func finish(_ failure: ADBError?) {
    finished = true
    self.failure = failure
    wake()
  }

  /// The next lines, waiting for some; `nil` once the queue is finished and empty. A batch holds
  /// at most `maxLines` lines and stops at `maxBytes`, but always takes one line.
  func take(maxLines: Int, maxBytes: Int) async -> LogBatch? {
    while lines.count == head {
      if finished { return nil }
      await withCheckedContinuation { waiter = $0 }
    }
    var batch: [String] = []
    var taken = 0
    while head < lines.count, batch.count < maxLines {
      let line = lines[head]
      if !batch.isEmpty, taken + line.count > maxBytes { break }
      batch.append(Self.text(line))
      taken += line.count
      bytes -= line.count
      head += 1
    }
    compact()
    defer { skipped = 0 }
    return LogBatch(lines: batch, skipped: skipped)
  }

  /// A line as text: bytes that are not UTF-8 become U+FFFD, so no line is ever lost to a bad
  /// byte.
  static func text(_ line: Data) -> String {
    var scalars = String.UnicodeScalarView()
    var bytes = line.makeIterator()
    var decoder = UTF8()
    while true {
      switch decoder.decode(&bytes) {
      case .scalarValue(let scalar): scalars.append(scalar)
      case .error: scalars.append("\u{FFFD}")
      case .emptyInput: return String(scalars)
      }
    }
  }

  private func compact() {
    guard head > 1024, head * 2 > lines.count else { return }
    lines.removeFirst(head)
    head = 0
  }

  private func wake() {
    waiter?.resume()
    waiter = nil
  }
}

/// A device's log streamed to the app that asked, over the reverse channel.
///
/// A reader task moves lines from the device into a bounded queue; this actor's request takes
/// batches from it and hands each to the client, then waits for the client to say it took it
/// before sending the next, so the stream goes at the client's pace. It ends when the client
/// says it wants no more or stops listening, when `stopLogcat` is called, when a new stream for
/// the device replaces it, when the device is no longer served over ADB by the route it began
/// on (an eject or a switch of method closes nothing on the adb connection), or when the device
/// or the adb server goes away.
extension ADBTools {
  /// Runs until the stream ends. A device lost meanwhile throws, as for any tool.
  public func streamLogcat(_ id: DeviceID, to sink: LogSink) async throws(TransportError)
    -> Outcome
  {
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    let source: any LogcatSource
    do throws(ADBError) {
      source = try await device.logcat(serial: serial)
    } catch {
      throw Self.transportError(error)
    }
    let run = LogcatRun(source: source)
    // One stream per device: this one replaces any other, which answers as stopped.
    logcats[id]?.stop()
    logcats[id] = run
    let queue = LogQueue(maxLines: limits.logQueueLines, maxBytes: limits.logQueueBytes)
    let reader = Task {
      do throws(ADBError) {
        while let lines = try await source.next() { await queue.push(lines) }
        await queue.finish(nil)
      } catch {
        await queue.finish(error)
      }
    }
    var outcome = Outcome.done
    var clientLeft = false
    let (batchLines, batchBytes) = (limits.logBatchLines, limits.logBatchBytes)
    while let batch = await queue.take(maxLines: batchLines, maxBytes: batchBytes) {
      if run.isStopped { break }
      guard await target(id) == serial else {
        outcome = .failed(.notOverADB)
        break
      }
      guard await sink(batch) else {
        clientLeft = true
        break
      }
      try? await Task.sleep(for: limits.logInterval)
    }
    // Whether somebody ended it, read before this ends it too.
    let stopped = run.isStopped
    reader.cancel()
    run.stop()
    if logcats[id] === run { logcats[id] = nil }
    if case .done = outcome, !stopped, !clientLeft, let failure = await queue.failure {
      throw Self.transportError(failure)
    }
    return outcome
  }

  /// Ends the device's log stream; answers `.done` even when none runs.
  public func stopLogcat(_ id: DeviceID) -> Outcome {
    logcats[id]?.stop()
    return .done
  }
}
