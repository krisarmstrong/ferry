import DeviceKit
import FerryIPC
import Foundation

/// Screen recordings: Record Screen, the indicator with Stop, then saving the video where
/// macOS saves screenshots. A video the app could not save waits on the device, with Choose
/// Folder… and Discard, and is tried again on its own only once a capture folder becomes
/// writable, never on every refresh.
extension AppModel {
  /// The device's recording: as the agent reports it, or as asked for until the agent answers.
  public func recording(on device: DeviceID) -> ActiveRecording? {
    recordings.first { $0.device == device }
      ?? requestedRecordings[device].map {
        ActiveRecording(device: device, started: $0, stopping: false)
      }
  }

  /// Whether the device's finished recording could not be saved and waits for the user.
  public func recordingUnsaved(on device: DeviceID) -> Bool {
    unsavedRecordings[device] != nil
  }

  /// Starts a recording. The agent answers once it has ended (Stop, or its time limit), and the
  /// video is collected then; meanwhile the status shows it running.
  public func startRecording(on device: DeviceID) async {
    guard recording(on: device) == nil else { return }
    requestedRecordings[device] = Date()
    let response = await sendTool(.startRecording(device), file: nil)
    requestedRecordings[device] = nil
    await refresh()
    if response == .done { await collectRecording(on: device) }
  }

  public func stopRecording(on device: DeviceID) async {
    _ = await sendTool(.stopRecording(device), file: nil)
    await refresh()
  }

  /// Choose Folder…: saves the waiting video where the user says.
  public func chooseRecordingDestination(on device: DeviceID) async {
    guard let recording = recordings.first(where: { $0.device == device && $0.finished }),
      let url = await services.chooseDestination(
        suggestedName: captureName(.recording, of: device, at: recording.started) + ".mp4")
    else { return }
    await collectRecording(
      on: device, into: [url.deletingLastPathComponent()],
      named: url.deletingPathExtension().lastPathComponent)
  }

  /// Discard: the agent deletes the waiting video from the device, and Record Screen returns.
  public func discardRecording(on device: DeviceID) async {
    _ = await sendTool(.discardRecording(device), file: nil)
    unsavedRecordings[device] = nil
    await refresh()
  }

  /// Collects each finished recording the status lists: not one being collected already, nor
  /// one on a device not served over ADB now (it was ejected: it waits until it is back), nor
  /// one the app could not save, until a capture folder that was not writable then is now.
  func collectFinishedRecordings() {
    let listed = Set(recordings.map(\.device))
    unsavedRecordings = unsavedRecordings.filter { listed.contains($0.key) }
    var writable: Set<URL>?
    for recording in recordings
    where recording.finished && !collectingRecordings.contains(recording.device) {
      guard let device = devices.first(where: { $0.id == recording.device }),
        DevicePresentation.offersTools(device)
      else { continue }
      if let failedWith = unsavedRecordings[recording.device] {
        let now = writable ?? writableCaptureFolders()
        writable = now
        guard !now.isSubset(of: failedWith) else { continue }
      }
      Task { await collectRecording(on: recording.device) }
    }
  }

  /// Saves a finished recording and shows it. A recording that finished while no request
  /// waited for it (the app was relaunched) is collected when the status lists it.
  func collectRecording(on device: DeviceID, into folders: [URL]? = nil, named name: String? = nil)
    async
  {
    guard let recording = recordings.first(where: { $0.device == device && $0.finished }),
      collectingRecordings.insert(device).inserted
    else { return }
    defer { collectingRecordings.remove(device) }
    let saved = await capture(
      .recording, named: name ?? captureName(.recording, of: device, at: recording.started),
      in: folders ?? services.captureFolders(), request: .saveRecording(device))
    unsavedRecordings[device] = saved ? nil : writableCaptureFolders()
    await refresh()
  }

  private func writableCaptureFolders() -> Set<URL> {
    Set(services.captureFolders().filter(CaptureFiles.isWritableFolder))
  }
}
