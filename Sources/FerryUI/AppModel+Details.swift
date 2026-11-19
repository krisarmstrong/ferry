import DeviceKit
import FerryIPC
import Foundation

/// What a device's details show: nothing (never read, or the read failed), "Loading details…"
/// while the first read runs, or what the device said.
enum DetailsShown: Equatable {
  case hidden
  case loading
  case loaded(AndroidDeviceInfo)
}

/// A device's details as last read, and when they were asked for: `nil` when a read was
/// cancelled, so the next one is due at once.
struct DetailsRead {
  var info: AndroidDeviceInfo?
  var requested: ContinuousClock.Instant?
  var reading: Bool
  /// A read has finished, failed or not: a retry is not the first read, so it shows nothing.
  var settled = false
}

/// One click on an address line; its own `click` tells a later click on the same line apart.
struct CopiedAddress: Equatable {
  let device: DeviceID
  let line: String
  let click = UUID()
}

/// The expanded device's details, inline in the menu. They are read when its row opens and
/// while the menu is open, at most every 10 s, and only for a device that offers the tools; a
/// read that fails shows nothing and keeps what an earlier one read.
extension AppModel {
  static let detailsInterval = Duration.seconds(10)
  static let copiedFor = Duration.milliseconds(1500)

  func shownDetails(of device: DeviceID) -> DetailsShown {
    guard let details = details[device] else { return .hidden }
    if let info = details.info { return .loaded(info) }
    return details.reading && !details.settled ? .loading : .hidden
  }

  /// Starts reading the expanded device's details, unless they are being read or were asked for
  /// in the last 10 s.
  func loadExpandedDetailsIfDue() {
    guard case .device(let id)? = expansion.expanded,
      let device = devices.first(where: { $0.id == id }), DevicePresentation.offersTools(device)
    else { return }
    let now = now()
    let busy = details[id].map { read in
      read.reading
        || read.requested.map { $0.duration(to: now) < Self.detailsInterval } ?? false
    }
    if busy == true { return }
    details[id] = DetailsRead(
      info: details[id]?.info, requested: now, reading: true, settled: details[id]?.settled ?? false
    )
    detailReads[id] = Task { await readDetails(of: id) }
  }

  /// Returns once every read started so far has finished.
  func detailsSettled() async {
    while let read = detailReads.values.first {
      await read.value
    }
  }

  /// Not through `sendTool`: a failure here is no action of the user's, so it shows nothing.
  /// A read cancelled because the menu closed leaves the details as they were, due again.
  private func readDetails(of id: DeviceID) async {
    var info: AndroidDeviceInfo?
    if !Task.isCancelled {
      if case .deviceInfo(let read)? = try? await client.send(.deviceInfo(id), file: nil) {
        info = read
      }
    }
    detailReads[id] = nil
    // The device went while it was read.
    guard var current = details[id] else { return }
    current.reading = false
    if Task.isCancelled {
      current.requested = nil
    } else {
      current.settled = true
      if let info { current.info = info }
    }
    details[id] = current
  }

  /// The menu closed: no read goes on without it.
  func cancelDetailReads() {
    for read in detailReads.values { read.cancel() }
  }

  func forgetDetailsOfGoneDevices() {
    let listed = Set(devices.map(\.id))
    for (id, read) in detailReads where !listed.contains(id) { read.cancel() }
    details = details.filter { listed.contains($0.key) }
    if let copied = copiedAddress, !listed.contains(copied.device) { copiedAddress = nil }
  }

  /// Copies the line's address and shows "Copied" in its place for 1.5 s on the injected clock.
  func copyAddress(_ line: DevicePresentation.DetailLine, on device: DeviceID) async {
    guard let address = line.address else { return }
    services.copy(address)
    let copied = CopiedAddress(device: device, line: line.id)
    copiedAddress = copied
    // Cancelled or not, the word goes.
    try? await sleep(Self.copiedFor)
    if copiedAddress == copied { copiedAddress = nil }
  }

  func isCopied(_ line: DevicePresentation.DetailLine, on device: DeviceID) -> Bool {
    copiedAddress?.device == device && copiedAddress?.line == line.id
  }

  /// Copy All Details: what the Device Info window copied, once the details are read.
  func copyAllDetails(of device: DeviceID) {
    guard let info = details[device]?.info else { return }
    services.copy(DevicePresentation.detailsText(info))
  }
}
