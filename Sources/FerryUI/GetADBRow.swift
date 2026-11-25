import AppKit
import SwiftUI

/// adb is missing, or Ferry is getting it: the offer to download Google's platform tools, the
/// download, or why it failed. Ferry never installs adb without the user accepting Google's
/// license in `PlatformToolsLicenseView`.
struct GetADBRow: View {
  let line: PlatformToolsLine
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    row.accessibilityElement(children: .contain)
  }

  @ViewBuilder private var row: some View {
    let title = MenuStatusText.platformTools(line)
    switch line {
    case .fetching:
      StatusRow(symbol: "arrow.down.circle", title: Text(title)) {
        StatusAction(title: Text("Cancel", bundle: .module)) { model.cancelPlatformTools() }
      }
    case .offer:
      StatusRow(symbol: "shippingbox", title: Text(title), help: title.key) {
        Text(
          "Ferry downloads adb from Google once. This needs an internet connection.",
          bundle: .module)
      } actions: {
        StatusAction(
          title: Text("Get Android Platform Tools…", bundle: .module), action: showLicense)
      }
    case .licenseChanged:
      StatusRow(symbol: "doc.text", title: Text(title), help: title.key) {
        Text(
          "Ferry keeps using the adb it has until you accept the new license.", bundle: .module)
      } actions: {
        StatusAction(title: Text("Review License…", bundle: .module), action: showLicense)
      }
    case .failed:
      StatusRow(
        symbol: "exclamationmark.triangle", severity: .warning, title: Text(title), help: title.key
      ) {
        StatusAction(title: Text("Try Again", bundle: .module)) { model.retryPlatformTools() }
      }
    }
  }

  private func showLicense() {
    NSApp.activate()
    openWindow(id: PlatformToolsLicenseView.windowID)
  }
}

/// adb is installed but its server does not answer.
struct ADBNotRunningRow: View {
  let checkAgain: () -> Void

  var body: some View {
    StatusRow(
      symbol: "exclamationmark.triangle", severity: .warning,
      title: Text(MenuStatusText.adbNotRunning), help: MenuStatusText.adbNotRunning.key
    ) {
      StatusAction(title: Text("Check Again", bundle: .module), action: checkAgain)
    }
    .accessibilityElement(children: .contain)
  }
}
