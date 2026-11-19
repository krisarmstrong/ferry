import DeviceKit
import FerryIPC
import Foundation

/// Why a finished recording waits on the device for the user.
enum UnsavedRecording: Equatable {
  /// No capture folder could take it: the folders that could take a file then. Tried again
  /// once another one can.
  case noFolder(Set<URL>)
  /// The device was lost during the save. Tried again once a status has shown it gone
  /// (`away`) and then served again.
  case deviceLost(away: Bool)
  /// The agent refused, or the video was broken off for another reason: only the user tries
  /// again.
  case refused
}

/// Screen recordings: Record Screen, the indicator with Stop, then saving the video where
/// macOS saves screenshots. A video the app could not save waits on the device, with Choose
/// Folder… and Discard, and is tried again on its own only once a capture folder becomes
/// writable or the device comes back, never on every refresh.
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
  /// A refused discard (the video is being saved) leaves it waiting as it was.
  public func discardRecording(on device: DeviceID) async {
    if await sendTool(.discardRecording(device), file: nil) == .done {
      unsavedRecordings[device] = nil
    }
    await refresh()
  }

  /// Collects each finished recording the status lists: not one being collected already, nor
  /// one on a device not served over ADB now (it was ejected: it waits until it is back), nor
  /// one the app could not save, until what stopped it changed (see `UnsavedRecording`).
  func collectFinishedRecordings() {
    let listed = Set(recordings.map(\.device))
    unsavedRecordings = unsavedRecordings.filter { listed.contains($0.key) }
    for recording in recordings
    where recording.finished && !collectingRecordings.contains(recording.device) {
      let id = recording.device
      guard let device = devices.first(where: { $0.id == id }),
        DevicePresentation.offersTools(device)
      else {
        if case .deviceLost = unsavedRecordings[id] {
          unsavedRecordings[id] = .deviceLost(away: true)
        }
        continue
      }
      switch unsavedRecordings[id] {
      case nil, .deviceLost(away: true):
        Task { await collectRecording(on: id) }
      case .deviceLost(away: false), .refused:
        continue
      case .noFolder(let failedWith):
        guard probingRecordings.insert(id).inserted else { continue }
        Task {
          let now = await writableCaptureFolders()
          probingRecordings.remove(id)
          guard !now.isSubset(of: failedWith), unsavedRecordings[id] == .noFolder(failedWith)
          else { return }
          await collectRecording(on: id)
        }
      }
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
    let result = await capture(
      .recording, named: name ?? captureName(.recording, of: device, at: recording.started),
      in: folders ?? services.captureFolders(), request: .saveRecording(device))
    switch result {
    case .saved:
      unsavedRecordings[device] = nil
    case .noFolder:
      unsavedRecordings[device] = .noFolder(await writableCaptureFolders())
    case .notSent(let response):
      unsavedRecordings[device] = Self.lostDevice(response) ? .deviceLost(away: false) : .refused
    }
    await refresh()
  }

  /// Whether a save failed because the device went away (unplugged, USB debugging turned off,
  /// adb's server gone), which a later try can get past once it is back.
  private static func lostDevice(_ response: AgentResponse?) -> Bool {
    switch response {
    case .failure(.deviceDisconnected), .failure(.deviceNotFound), .failure(.noDeviceConnected),
      .toolFailed(.notOverADB):
      true
    default:
      false
    }
  }

  /// The capture folders that take a new file now. Checked by creating one, off the main
  /// thread: a folder macOS protects passes a permission check but refuses the file, and can
  /// hold the call while it asks the user.
  private func writableCaptureFolders() async -> Set<URL> {
    let folders = services.captureFolders()
    return await Task.detached { Set(folders.filter(CaptureFiles.takesNewFiles)) }.value
  }
}
