import DeviceKit
import FerryIPC

/// Which row of the menu is expanded, as in Control Center: one at most.
///
/// Opening the menu expands nothing until its first status arrives; that status, or the first
/// later one that lists a ready device, expands the first ready device. From then on the open
/// row stays open while it exists, whatever happens to the device (an Eject must leave Mount in
/// view) and whichever devices become ready, until the user picks another row or closes it. A
/// row that goes away collapses, and nothing opens in its place.
struct MenuExpansion: Equatable, Sendable {
  /// A row that expands. A remembered device and an address offered for a known device have
  /// rows of their own, apart from that device's.
  enum Row: Hashable, Sendable {
    case device(DeviceID)
    case remembered(DeviceID)
    case offer(WirelessEndpoint)
  }

  private(set) var expanded: Row?
  /// Whether the first ready device is still to be expanded: until one is, or the user acts.
  private var awaitingDefault = true

  mutating func toggle(_ row: Row) {
    expanded = expanded == row ? nil : row
    awaitingDefault = false
  }

  /// The menu opened: nothing is expanded until a status arrives.
  mutating func reset() {
    expanded = nil
    awaitingDefault = true
  }

  /// A status arrived with these rows.
  mutating func update(rows: [Row], firstReady: Row?) {
    if awaitingDefault {
      guard let firstReady else { return }
      expanded = firstReady
      awaitingDefault = false
    } else if let expanded, !rows.contains(expanded) {
      self.expanded = nil
    }
  }
}

extension AppModel {
  func toggleExpansion(_ row: MenuExpansion.Row) {
    expansion.toggle(row)
  }

  func isExpanded(_ row: MenuExpansion.Row) -> Bool {
    expansion.expanded == row
  }

  /// The menu's rows that expand, in menu order.
  private var expandingRows: [MenuExpansion.Row] {
    devices.map { .device($0.id) } + rememberedOffline.map { .remembered($0.id) }
      + unconfirmed.map { .offer($0.address) }
  }

  private var firstReadyRow: MenuExpansion.Row? {
    devices.first { if case .ready = $0.state { true } else { false } }.map { .device($0.id) }
  }

  func resetExpansion() {
    expansion.reset()
  }

  func updateExpansion() {
    expansion.update(rows: expandingRows, firstReady: firstReadyRow)
  }
}
