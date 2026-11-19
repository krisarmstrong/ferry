import DeviceKit
import FerryIPC
import Foundation
import Observation

/// One device's log window: the agent streams `logcat -v threadtime` in batches, the newest
/// 50,000 lines are held, and the filters, Pause, Clear and Save work on what is held.
///
/// Pause freezes what the window shows and nothing else: lines keep arriving, and Resume shows
/// them. Save writes every held line that passes the filters, from the app: the agent never
/// touches the user's folders.
@Observable @MainActor final class LogcatSession {
  enum State: Equatable {
    case running
    /// The stream is over, with why, in words for the user.
    case ended(String)
  }

  let device: DeviceID
  private let model: String
  private let client: any AgentSending
  private let services: any SystemServicing

  private(set) var state = State.running
  /// The lines the window shows, filtered; frozen while paused.
  private(set) var shown: [LogcatEntry] = []
  private(set) var isPaused = false
  private(set) var saveError: String?
  var minimumLevel = LogcatEntry.Level.verbose {
    didSet { refresh() }
  }
  var filterText = "" {
    didSet { refresh() }
  }

  private var buffer = LogcatBuffer()
  /// While paused, only lines before this identifier are shown.
  private var pausedBefore: Int?
  private var closing = false

  init(
    device: DeviceID, model: String, client: any AgentSending, services: any SystemServicing
  ) {
    self.device = device
    self.model = model
    self.client = client
    self.services = services
  }

  /// How many lines are held.
  var held: Int { buffer.count }

  /// Streams until the stream ends or the window closes.
  func run() async {
    state = .running
    closing = false
    let response: AgentResponse?
    do {
      response = try await client.send(
        .startLogcat(device), file: nil, progress: nil,
        logs: { [weak self] batch in await self?.receive(batch) })
    } catch {
      response = nil
      if !closing, error != .cancelled { state = .ended(DevicePresentation.message(for: error)) }
    }
    guard !closing, let response else { return }
    switch response {
    case .toolFailed(let failure): state = .ended(DevicePresentation.message(for: failure))
    case .failure(let error): state = .ended(DevicePresentation.message(for: error))
    default: state = .ended(DevicePresentation.logEndedLine)
    }
  }

  /// The window closed: the agent stops streaming.
  func close() async {
    closing = true
    _ = try? await client.send(.stopLogcat(device), file: nil)
  }

  func receive(_ batch: LogBatch) {
    if batch.skipped > 0 { buffer.append([DevicePresentation.skippedLinesLine(batch.skipped)]) }
    buffer.append(batch.lines)
    refresh()
  }

  func togglePause() {
    isPaused.toggle()
    pausedBefore = isPaused ? buffer.nextID : nil
    refresh()
  }

  func clear() {
    buffer.removeAll()
    if isPaused { pausedBefore = buffer.nextID }
    refresh()
  }

  /// Save…: asks where, then writes the held lines that pass the filters, one per line.
  func save() async {
    let name = CaptureFiles.baseName(.logcat, model: model, at: Date()) + ".txt"
    guard let url = await services.chooseLogDestination(suggestedName: name) else { return }
    let lines = buffer.shown(minimum: minimumLevel, matching: filterText).map(\.text)
    let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    do {
      try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value
      saveError = nil
    } catch {
      saveError = DevicePresentation.saveLogFailure(error.localizedDescription)
    }
  }

  private func refresh() {
    shown = buffer.shown(minimum: minimumLevel, matching: filterText, before: pausedBefore)
  }
}
