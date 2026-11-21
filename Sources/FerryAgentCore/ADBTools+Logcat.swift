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

  /// Nothing is waiting to be taken.
  var isEmpty: Bool { lines.count == head }

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
/// before sending the next, so the stream goes at the client's pace. A watchdog checks every
/// `routeWatch` that the device is still served over ADB by the route the stream began on (an
/// eject or a switch of method closes nothing on the adb connection) and closes the stream if
/// not, which ends a read waiting on a silent log. The same watchdog ends the stream once the
/// client cancels the request or its connection drops. It also ends when the client says it
/// wants no more, when its own stop arrives, when a new stream for the device replaces it, or
/// when the device or the adb server goes away.
extension ADBTools {
  /// Runs until the stream ends. A device lost meanwhile throws, as for any tool.
  public func streamLogcat(_ id: DeviceID, stream: UUID, to sink: LogSink)
    async throws(TransportError) -> Outcome
  {
    guard let route = await target(id) else { return .failed(.notOverADB) }
    let source: any LogcatSource
    do throws(ADBError) {
      source = try await device.logcat(route: route)
    } catch {
      throw Self.transportError(error)
    }
    let run = LogcatRun(id: stream, source: source)
    // A stop that came while this was connecting ends it before it starts.
    if pendingStops.remove(stream) != nil {
      run.stop()
      return .done
    }
    // One stream per device: this one replaces any other, which answers as stopped.
    logcats[id]?.stop()
    logcats[id] = run
    let queue = LogQueue(maxLines: limits.logQueueLines, maxBytes: limits.logQueueBytes)
    let reader = Self.read(source, into: queue)
    let watchdog = watch(
      id, route: route, run, cancellation: RequestCancellation.current, every: limits.routeWatch)
    let clientLeft = await deliver(queue, run, to: sink)
    // Whether somebody ended it, read before this ends it too.
    let (stopped, lost) = (run.isStopped, run.isRouteLost)
    watchdog.cancel()
    reader.cancel()
    run.stop()
    if logcats[id] === run { logcats[id] = nil }
    if lost, !stopped { return .failed(.notOverADB) }
    if !stopped, !clientLeft, let failure = await queue.failure {
      throw Self.transportError(failure)
    }
    return .done
  }

  /// Moves lines from the device into the queue until the log ends or fails.
  private static func read(_ source: any LogcatSource, into queue: LogQueue) -> Task<Void, Never> {
    Task {
      do throws(ADBError) {
        while let lines = try await source.next() { await queue.push(lines) }
        await queue.finish(nil)
      } catch {
        await queue.finish(error)
      }
    }
  }

  /// Closes the stream, which ends a read waiting on a silent log, once the device is no longer
  /// served over ADB by `route` (the same connection), or the client has cancelled the request.
  private func watch(
    _ id: DeviceID, route: ADBRoute, _ run: LogcatRun, cancellation: RequestCancellation?,
    every interval: Duration
  ) -> Task<Void, Never> {
    let target = target
    return Task {
      while (try? await Task.sleep(for: interval)) != nil {
        if cancellation?.isCancelled == true {
          run.stop()
          return
        }
        if await target(id) != route {
          run.routeLost()
          return
        }
      }
    }
  }

  /// Sends batches to `sink` until the queue ends, the stream is stopped or lost, or the client
  /// wants no more (then true).
  private func deliver(_ queue: LogQueue, _ run: LogcatRun, to sink: LogSink) async -> Bool {
    let (batchLines, batchBytes) = (limits.logBatchLines, limits.logBatchBytes)
    while let batch = await queue.take(maxLines: batchLines, maxBytes: batchBytes) {
      if run.isStopped || run.isRouteLost { return false }
      guard await sink(batch) else { return true }
      // A backlog goes out at once; the pause only batches up a log that is keeping pace.
      if await queue.isEmpty { try? await clock.sleep(for: limits.logInterval) }
    }
    return false
  }

  /// Ends the device's log stream `stream`, if it is the one running or still connecting; a
  /// stop for a stream already replaced or ended does nothing.
  public func stopLogcat(_ id: DeviceID, stream: UUID) -> Outcome {
    if let run = logcats[id], run.id == stream {
      run.stop()
    } else {
      // Not running (yet): remembered, so a stream still connecting ends when it is up.
      if pendingStops.count >= 64 { pendingStops.removeAll() }
      pendingStops.insert(stream)
    }
    return .done
  }
}
