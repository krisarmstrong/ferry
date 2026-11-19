import FerryIPC
import Foundation
import Synchronization

/// What each Finder menu item does, kept from the menu it was built in.
///
/// Finder copies the menu, so only an item's tag comes back with the click, and it may build
/// another menu before then (the device list changed, another window asked). Every actionable
/// item gets a tag never given before, bound to the action, the device's name and the selection
/// of its own menu, so a click acts on exactly what that menu showed: two devices of one model
/// can never swap, and Install never runs on a selection it was not offered for.
public final class FinderMenuBook: Sendable {
  public struct Choice: Equatable, Sendable {
    public let action: FinderAction
    /// The device's name as the menu showed it.
    public let device: String
    public let selection: [URL]

    public init(action: FinderAction, device: String, selection: [URL]) {
      self.action = action
      self.device = device
      self.selection = selection
    }
  }

  /// How many recent menus keep their items: enough for menus built before a click, few enough
  /// that the book stays small however long Finder runs.
  public static let menusKept = 8

  private struct State {
    var nextTag = 1
    var choices: [Int: Choice] = [:]
    /// The tags of each kept menu, oldest first.
    var menus: [[Int]] = []
  }

  private let state = Mutex(State())

  public init() {}

  /// Records a menu built from `devices` and `selection`, and returns each entry's tag: `nil`
  /// for a disabled line.
  public func record(_ entries: [FinderMenuEntry], devices: [DeviceSummary], selection: [URL])
    -> [Int?]
  {
    let names = Dictionary(
      devices.map { ($0.id, FinderMenu.displayName(of: $0)) },
      uniquingKeysWith: { first, _ in first })
    return state.withLock { state in
      var tags: [Int?] = []
      var menu: [Int] = []
      for entry in entries {
        guard let action = entry.action else {
          tags.append(nil)
          continue
        }
        let tag = state.nextTag
        state.nextTag += 1
        state.choices[tag] = Choice(
          action: action, device: names[action.device] ?? "", selection: selection)
        tags.append(tag)
        menu.append(tag)
      }
      state.menus.append(menu)
      while state.menus.count > Self.menusKept {
        for tag in state.menus.removeFirst() { state.choices[tag] = nil }
      }
      return tags
    }
  }

  /// What the item tagged `tag` does, if its menu is still kept.
  public func choice(for tag: Int) -> Choice? {
    state.withLock { $0.choices[tag] }
  }
}
