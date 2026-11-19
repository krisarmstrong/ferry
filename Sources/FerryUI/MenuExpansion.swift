import DeviceKit
import FerryIPC

/// Which row of the menu is expanded, as in Control Center: one at most. Until the user expands
/// or collapses a row, the first ready device as the latest status lists it is expanded, so the
/// status read on opening decides it, and a device plugged in while the menu is open shows its
/// actions too.
struct MenuExpansion: Equatable, Sendable {
  /// A row that expands. A remembered device and an address offered for a known device have
  /// rows of their own, apart from that device's.
  enum Row: Hashable, Sendable {
    case device(DeviceID)
    case remembered(DeviceID)
    case offer(WirelessEndpoint)
  }

  private(set) var expanded: Row?
  private var followsDefault = true

  mutating func toggle(_ row: Row) {
    expanded = expanded == row ? nil : row
    followsDefault = false
  }

  /// The menu opened: back to the first ready device.
  mutating func reset(rows: [Row], firstReady: Row?) {
    expanded = nil
    followsDefault = true
    update(rows: rows, firstReady: firstReady)
  }

  /// The rows changed: a row that went away is no longer expanded.
  mutating func update(rows: [Row], firstReady: Row?) {
    if followsDefault {
      expanded = firstReady
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
    expansion.reset(rows: expandingRows, firstReady: firstReadyRow)
  }

  func updateExpansion() {
    expansion.update(rows: expandingRows, firstReady: firstReadyRow)
  }
}
