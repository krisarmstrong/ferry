import AppKit
import FerryIPC
import FerrySyncCore
import FinderSync
import Synchronization
import UserNotifications
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "FinderSync")

/// Ferry's Finder menu: Send to <device> for selected files, Install on <device> for apps, in
/// the Control-click menu and the toolbar item. Everything it does goes through the agent; this
/// class only reads Finder's selection, builds the menu (see `FinderMenu`) and reports the
/// outcome in a notification, since Finder Sync has no progress UI.
final class FinderSync: FIFinderSync {
  private let devices: DeviceList
  private let sender: FinderSender
  /// The action and device name of each item of the menu Finder last asked for, by item tag:
  /// Finder copies the menu, so only the tag comes back with the click.
  private let actions = Mutex<[Int: (action: FinderAction, device: String)]>([:])

  override init() {
    // The build records the signing team in Info.plist; `make app` checks it is there.
    guard let identity = FerryIdentity() else {
      preconditionFailure("FerryTeamID is missing from the extension's Info.plist")
    }
    let client = AgentClient(identity: identity)
    devices = DeviceList(agent: client)
    sender = FinderSender(agent: client)
    super.init()
    // Every folder, so the menu is there for any selection.
    FIFinderSyncController.default().directoryURLs = [URL(filePath: "/")]
  }

  override var toolbarItemName: String { "Ferry" }

  override var toolbarItemToolTip: String { FinderMenu.toolbarToolTip }

  override var toolbarItemImage: NSImage {
    NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil) ?? NSImage()
  }

  override func menu(for menuKind: FIMenuKind) -> NSMenu? {
    guard menuKind == .contextualMenuForItems || menuKind == .toolbarItemMenu else { return nil }
    let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
    let attached = devices.fresh(waitingUpTo: .milliseconds(500))
    let names = Dictionary(
      attached.map { ($0.id, FinderMenu.displayName(of: $0)) },
      uniquingKeysWith: { first, _ in first })
    let menu = NSMenu(title: "")
    menu.autoenablesItems = false
    var table: [Int: (action: FinderAction, device: String)] = [:]
    for (index, entry) in FinderMenu.entries(devices: attached, selection: selection).enumerated() {
      let item = NSMenuItem(
        title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
      item.tag = index
      if let action = entry.action {
        table[index] = (action, names[action.device] ?? "")
      } else {
        item.isEnabled = false
      }
      menu.addItem(item)
    }
    actions.withLock { $0 = table }
    return menu
  }

  @objc func choose(_ item: NSMenuItem) {
    let selection = FIFinderSyncController.default().selectedItemURLs() ?? []
    guard let chosen = actions.withLock({ $0[item.tag] }), !selection.isEmpty else { return }
    let sender = sender
    Task {
      let notice = await sender.perform(chosen.action, on: selection, deviceName: chosen.device)
      await Self.post(notice)
    }
  }

  /// Shows the outcome as a notification from Ferry. The extension posts it: it alone knows how
  /// the request ended, and the agent never talks to the user.
  private static func post(_ notice: FinderNotice) async {
    let center = UNUserNotificationCenter.current()
    do {
      guard try await center.requestAuthorization(options: [.alert]) else {
        log.info("notifications are off for Ferry")
        return
      }
      let content = UNMutableNotificationContent()
      content.title = notice.title
      content.body = notice.body
      try await center.add(
        UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    } catch {
      log.error("cannot post a notification: \(error, privacy: .public)")
    }
  }
}
