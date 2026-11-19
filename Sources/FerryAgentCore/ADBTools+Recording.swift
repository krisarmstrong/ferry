import ADBTransport
import DeviceKit
import FerryIPC
import Foundation

/// Screen recordings: one per device, from start until the app collects the video.
extension ADBTools {
  public func recordingsRunning() -> [ActiveRecording] {
    recordings.map {
      ActiveRecording(
        device: $0.key, started: $0.value.started, stopping: $0.value.stopping,
        finished: $0.value.end != nil)
    }
    .sorted { $0.started < $1.started }
  }

  /// Whether the device has something under way over ADB that a restart of its adbd would cut
  /// off: a recording still running or being pulled, or a log stream. A finished recording that
  /// waits on the device is not cut off.
  public func isBusy(_ id: DeviceID) -> Bool {
    if logcats[id] != nil { return true }
    guard let recording = recordings[id] else { return false }
    return recording.end == nil || recording.collecting
  }

  /// Records until Stop, the time limit, or the process ending, and answers `.done` then: the
  /// video waits on the device for `saveRecording`. A device lost meanwhile is disconnected and
  /// its file is left for the next session's sweep.
  public func startRecording(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard recordings[id] == nil else { return .failed(.alreadyRecording) }
    let recording = Recording(started: now())
    recordings[id] = recording
    guard let serial = await target(id) else {
      recordings[id] = nil
      return .failed(.notOverADB)
    }
    recordings[id]?.serial = serial
    await journal.note(recording.path, on: id)
    let control: any ScreenRecordingControl
    do throws(ADBError) {
      control = try await device.recordScreen(serial: serial, to: recording.path)
    } catch {
      recordings[id] = nil
      await removeFromDevice(recording.path, of: id, serial: serial)
      throw Self.transportError(error)
    }
    recordings[id]?.control = control
    if recordings[id]?.stopping == true { try? await stop(id, token: recording.token, control) }
    let watchdog = Task { [limits] in
      // screenrecord stops at its own limit; this is for one that does not.
      guard (try? await Task.sleep(for: limits.recording + limits.grace)) != nil else { return }
      toolsLog.error("a recording outlived its time limit; stopping it")
      // The kill may never answer on a wedged device; the close below does not wait for it.
      Task { try? await control.interrupt() }
      guard (try? await Task.sleep(for: limits.stopWait)) != nil else { return }
      await control.abandon()
    }
    let end = await control.finished()
    watchdog.cancel()
    if case .lost(let error) = end {
      recordings[id] = nil
      await journal.release(recording.path)
      throw Self.transportError(error)
    }
    recordings[id]?.end = end
    return .done
  }

  public func stopRecording(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard let recording = recordings[id], recording.end == nil else {
      return .failed(.notRecording)
    }
    recordings[id]?.stopping = true
    // Still starting: `startRecording` stops it once it has a pid.
    guard let control = recording.control else { return .done }
    try await stop(id, token: recording.token, control)
    return .done
  }

  /// Copies a finished recording into `file`, a writable descriptor from the client, and removes
  /// it from the device. One with no video is `recordingFailed` with the process's own words; one
  /// larger than any real recording is removed and reported as such.
  ///
  /// The device must still be served over ADB, by the route it uses now: an ejected device is
  /// left alone, and its video waits until it is served again. A pull the device or the Mac
  /// broke off, or that stopped arriving (a Wi-Fi roam, a busy link), keeps the recording, on the
  /// device and in the journal, for another try.
  public func saveRecording(_ id: DeviceID, into file: Int32) async throws(TransportError)
    -> Outcome
  {
    try FileTransfer.requireRegular(file)
    guard let recording = recordings[id] else { return .failed(.notRecording) }
    guard recording.end != nil, !recording.collecting else { return .failed(.recordingBusy) }
    guard let serial = await target(id) else { return .failed(.notOverADB) }
    guard let current = recordings[id], current.token == recording.token, !current.collecting,
      let control = current.control, let end = current.end
    else { return .failed(.recordingBusy) }
    recordings[id]?.collecting = true
    var detail = ""
    if case .exited(_, let text) = end { detail = text }
    let staged = FileTransfer.scratchURL(in: scratch)
    defer { FileTransfer.remove(staged) }
    let pulled: Result<Pulled, TransportError> = await pull(
      control, serial: serial, into: staged)
    let failure: ToolFailure
    switch pulled {
    case .failure(let error):
      recordings[id]?.collecting = false
      throw error
    case .success(.tooLarge): failure = .recordingTooLarge
    case .success(.stalled):
      recordings[id]?.collecting = false
      return .failed(.recordingStalled)
    case .success(.noFile): failure = .recordingFailed(detail)
    case .success(.pulled):
      guard Self.isMP4(at: staged) else {
        failure = .recordingFailed(detail)
        break
      }
      do throws(TransportError) {
        try await FileTransfer.copyOut(staged, to: file)
      } catch {
        // The Mac could not take it: the video stays on the device for another try.
        recordings[id]?.collecting = false
        throw error
      }
      await finish(id, path: recording.path, serial: serial)
      return .done
    }
    await finish(id, path: recording.path, serial: serial)
    return .failed(failure)
  }

  /// Deletes a finished recording the app will not save, from the device and the journal. A
  /// device not served now keeps the file until its next session's sweep.
  public func discardRecording(_ id: DeviceID) async throws(TransportError) -> Outcome {
    guard let recording = recordings[id] else { return .failed(.notRecording) }
    guard recording.end != nil, !recording.collecting else { return .failed(.recordingBusy) }
    recordings[id]?.collecting = true
    if let serial = await target(id) {
      await finish(id, path: recording.path, serial: serial)
    } else {
      recordings[id] = nil
      await journal.release(recording.path)
    }
    return .done
  }

  /// Removes a recording the app is done with, from the device and from the list.
  private func finish(_ id: DeviceID, path: String, serial: String) async {
    recordings[id] = nil
    await removeFromDevice(path, of: id, serial: serial)
  }

  enum Pulled {
    case pulled
    /// The device refused the pull: there is no file.
    case noFile
    case tooLarge
    case stalled
  }

  /// Pulls the recording into the agent's own `staged` file, at most `limits.recordingSize`
  /// bytes, given up once no data has arrived for `limits.pullStall`. Fails when the device went
  /// away or the Mac has no room for it.
  private func pull(_ control: any ScreenRecordingControl, serial: String, into staged: URL)
    async -> Result<Pulled, TransportError>
  {
    guard FileManager.default.createFile(atPath: staged.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: staged)
    else { return .failure(.io(String(localized: AgentText.recordingNotStaged))) }
    defer { try? handle.close() }
    let watch = PullWatch(limit: limits.recordingSize, folder: staged.deletingLastPathComponent())
    // A client's cancel stops the pull as the device breaking it off does: the recording waits.
    let cancellation = RequestCancellation.current
    let progress: ProgressHandler = { done, total in
      cancellation?.isCancelled != true && watch.progress(done, total)
    }
    let pulling = Task { () -> Result<UInt64, ADBError> in
      do throws(ADBError) {
        return .success(try await control.pull(into: handle, serial: serial, progress: progress))
      } catch {
        return .failure(error)
      }
    }
    let stall = limits.pullStall
    let watchdog = Task {
      while (try? await Task.sleep(for: stall / 4)) != nil {
        if watch.idle(longerThan: stall) {
          pulling.cancel()
          return
        }
      }
    }
    let result = await pulling.value
    watchdog.cancel()
    // A pull that completed as the watchdog gave up on it completed; only a recording larger
    // than any real one is refused whatever arrived.
    switch (watch.stop, result) {
    case (.tooLarge, _): return .success(.tooLarge)
    case (_, .success): return .success(.pulled)
    case (.noRoom(let error), _): return .failure(error)
    case (.stalled, _): return .success(.stalled)
    case (nil, .failure(let error)):
      let mapped = Self.transportError(error)
      if case .failed = error, mapped != .deviceDisconnected { return .success(.noFile) }
      return .failure(mapped)
    }
  }

  /// An MP4 starts with a box whose type is `ftyp`.
  static func isMP4(at url: URL) -> Bool {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    let head = (try? handle.read(upToCount: 12)) ?? Data()
    return head.count == 12 && head.dropFirst(4).prefix(4) == Data("ftyp".utf8)
  }

  /// The close is armed first, so a kill that never answers still frees the device.
  private func stop(_ id: DeviceID, token: UUID, _ control: any ScreenRecordingControl)
    async throws(TransportError)
  {
    Task { [limits] in
      guard (try? await Task.sleep(for: limits.stopWait)) != nil else { return }
      await self.abandon(id, token: token, control)
    }
    do throws(ADBError) {
      try await control.interrupt()
    } catch {
      throw Self.transportError(error)
    }
  }

  /// Closes a recording that has not ended `stopWait` after Stop.
  private func abandon(_ id: DeviceID, token: UUID, _ control: any ScreenRecordingControl) async {
    guard let recording = recordings[id], recording.token == token, recording.end == nil else {
      return
    }
    toolsLog.error("a recording did not end after Stop; closing it")
    await control.abandon()
  }
}
