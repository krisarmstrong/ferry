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
  /// it from the device. One with no video is `recordingFailed` with the process's own words.
  public func saveRecording(_ id: DeviceID, into file: Int32) async throws(TransportError)
    -> Outcome
  {
    try FileTransfer.requireRegular(file)
    guard let recording = recordings[id], let end = recording.end, let serial = recording.serial,
      let control = recording.control, !recording.collecting
    else { return .failed(recordings[id] == nil ? .notRecording : .alreadyRecording) }
    recordings[id]?.collecting = true
    var detail = ""
    if case .exited(_, let text) = end { detail = text }
    let staged = FileTransfer.scratchURL(in: scratch)
    defer { FileTransfer.remove(staged) }
    let pulled: Result<Bool, TransportError> = await pull(control, into: staged)
    recordings[id] = nil
    switch pulled {
    case .failure(let error):
      // The device went away: its file stays journalled for the next session.
      await journal.release(recording.path)
      throw error
    case .success(let gotFile):
      await removeFromDevice(recording.path, of: id, serial: serial)
      guard gotFile, Self.isMP4(at: staged) else { return .failed(.recordingFailed(detail)) }
      try await FileTransfer.copyOut(staged, to: file)
      return .done
    }
  }

  /// Pulls the recording into the agent's own `staged` file: whether the device had a file, or
  /// the device lost.
  private func pull(_ control: any ScreenRecordingControl, into staged: URL) async
    -> Result<Bool, TransportError>
  {
    guard FileManager.default.createFile(atPath: staged.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: staged)
    else { return .failure(.io("cannot stage the recording")) }
    defer { try? handle.close() }
    do throws(ADBError) {
      _ = try await control.pull(into: handle) { _, _ in true }
      return .success(true)
    } catch {
      let mapped = Self.transportError(error)
      // The device refused the pull: there is no file. Otherwise the device went away.
      if case .failed = error, mapped != .deviceDisconnected { return .success(false) }
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
