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
    /// The stream is over, with why, in words for the user and its entry in Help.
    case ended(MenuNotice)
  }

  let device: DeviceID
  /// The device as the menu names it, unescaped: it only names the saved file.
  private let name: String
  private let client: any AgentSending
  private let services: any SystemServicing

  private(set) var state = State.running
  /// The lines the window shows, filtered; frozen while paused.
  private(set) var shown: [LogcatEntry] = []
  private(set) var isPaused = false
  private(set) var saveError: MenuNotice?
  var minimumLevel = LogcatEntry.Level.verbose {
    didSet { refresh() }
  }
  var filterText = "" {
    didSet { refresh() }
  }

  private var buffer = LogcatBuffer()
  /// How many lines the filters have looked at, for a test of what a batch costs.
  private(set) var evaluations = 0
  /// While paused, only lines before this identifier are shown.
  private var pausedBefore: Int?
  private var closing = false
  /// Names this window's current stream to the agent, so closing a window never ends a newer
  /// one; each run has its own.
  private(set) var stream = UUID()

  init(
    device: DeviceID, name: String, client: any AgentSending, services: any SystemServicing
  ) {
    self.device = device
    self.name = name
    self.client = client
    self.services = services
  }

  /// How many lines are held.
  var held: Int { buffer.count }

  /// Streams until the stream ends or the window closes. Run again after it ended (Restart), it
  /// starts a new stream.
  func run() async {
    stream = UUID()
    state = .running
    closing = false
    let response: AgentResponse?
    do {
      response = try await client.send(
        .startLogcat(device, stream: stream), file: nil, progress: nil,
        logs: { [weak self] batch in await self?.receive(batch) })
    } catch {
      response = nil
      if !closing, error != .cancelled { state = .ended(DevicePresentation.notice(for: error)) }
    }
    guard !closing, let response else { return }
    switch response {
    case .toolFailed(let failure): state = .ended(DevicePresentation.notice(for: failure))
    case .failure(let error): state = .ended(DevicePresentation.notice(for: error))
    default: state = .ended(DevicePresentation.logEnded)
    }
  }

  /// The window closed: the agent stops streaming.
  func close() async {
    closing = true
    _ = try? await client.send(.stopLogcat(device, stream: stream), file: nil)
  }

  /// Adds a batch: only its lines are filtered, and what the buffer dropped leaves the front of
  /// what is shown. Paused, the window does not move: Resume shows what came meanwhile.
  func receive(_ batch: LogBatch) {
    var lines = batch.lines
    if batch.skipped > 0 { lines.insert(DevicePresentation.skippedLinesLine(batch.skipped), at: 0) }
    let added = buffer.append(lines)
    guard !isPaused else { return }
    let oldest = buffer.firstID
    let stale = shown.prefix { $0.id < oldest }.count
    if stale > 0 { shown.removeFirst(stale) }
    evaluations += added.count
    let (minimum, text) = (minimumLevel, filterText)
    shown.append(
      contentsOf: added.filter {
        $0.id >= oldest && LogcatBuffer.passes($0, minimum: minimum, matching: text)
      })
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
    let name = CaptureFiles.baseName(.logcat, model: name, at: Date()) + ".txt"
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

  /// Filters everything held again: after a filter changed, Clear or Resume.
  private func refresh() {
    evaluations += buffer.count
    shown = buffer.shown(minimum: minimumLevel, matching: filterText, before: pausedBefore)
  }
}
