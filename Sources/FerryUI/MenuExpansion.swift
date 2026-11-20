import DeviceKit
import FerryIPC

/// Which row of the menu is expanded, as in Control Center: one at most, and only one the user
/// opened.
///
/// Every row is collapsed each time the menu opens, and nothing expands by itself. The row the
/// user opens stays open while it exists, whatever happens to the device (an Eject must leave
/// Mount in view), until the user picks another row or closes it. A row that goes away
/// collapses, and nothing opens in its place.
struct MenuExpansion: Equatable, Sendable {
  /// A row that expands. A remembered device and an address offered for a known device have
  /// rows of their own, apart from that device's.
  enum Row: Hashable, Sendable {
    case device(DeviceID)
    case remembered(DeviceID)
    case offer(WirelessEndpoint)
  }

  private(set) var expanded: Row?

  mutating func toggle(_ row: Row) {
    expanded = expanded == row ? nil : row
  }

  /// The menu opened: every row is collapsed.
  mutating func reset() {
    expanded = nil
  }

  /// A status arrived with these rows.
  mutating func update(rows: [Row]) {
    if let expanded, !rows.contains(expanded) {
      self.expanded = nil
    }
  }
}

extension AppModel {
  /// The user opened or closed a row. A device opened shows its details, read now unless they
  /// were read in the last 10 s, with its Port Forwarding closed.
  func toggleExpansion(_ row: MenuExpansion.Row) {
    expansion.toggle(row)
    forwardsOpen = nil
    loadExpandedDetailsIfDue()
  }

  func isExpanded(_ row: MenuExpansion.Row) -> Bool {
    expansion.expanded == row
  }

  /// The menu's rows that expand, in menu order.
  private var expandingRows: [MenuExpansion.Row] {
    devices.map { .device($0.id) } + rememberedOffline.map { .remembered($0.id) }
      + unconfirmed.map { .offer($0.address) }
  }

  func resetExpansion() {
    expansion.reset()
    forwardsOpen = nil
  }

  func updateExpansion() {
    expansion.update(rows: expandingRows)
  }
}
