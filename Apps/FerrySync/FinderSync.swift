import AppKit
import FerryIPC
import FerrySyncCore
import FinderSync
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
  /// What each menu item does, bound to its own menu (see `FinderMenuBook`).
  private let book = FinderMenuBook()

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
    let listed = devices.fresh(waitingUpTo: .milliseconds(500))
    let entries = FinderMenu.entries(devices: listed, selection: selection)
    let tags = book.record(entries, devices: listed, selection: selection)
    let menu = NSMenu(title: "")
    menu.autoenablesItems = false
    for (entry, tag) in zip(entries, tags) {
      let item = NSMenuItem(title: entry.title, action: #selector(choose(_:)), keyEquivalent: "")
      if let tag {
        item.tag = tag
      } else {
        item.isEnabled = false
      }
      menu.addItem(item)
    }
    return menu
  }

  /// Acts on the device and the selection of the menu the item came from.
  @objc func choose(_ item: NSMenuItem) {
    guard let choice = book.choice(for: item.tag), !choice.selection.isEmpty else { return }
    let sender = sender
    // FinderSync, not Self: Swift 6.3's region-based isolation checker stops with an internal
    // error on a task that captures the dynamic Self type.
    Task {
      let notice = await sender.perform(
        choice.action, on: choice.selection, deviceName: choice.device)
      await FinderSync.post(notice)
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
