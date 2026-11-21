import AppKit
import SwiftUI

/// "Welcome to Ferry": shown once on a Mac new to Ferry, with the steps still needed, each in
/// the menu's row style with its next step and a Help link. It follows the status while open, so
/// a step ticks itself off once done. Help's Show Welcome Window opens it again.
public struct WelcomeView: View {
  public static let windowID = "welcome"
  public static let windowTitle = Text("Welcome to Ferry", bundle: .module)

  @Environment(\.dismissWindow) private var dismissWindow
  private let model: AppModel
  private let icon: NSImage

  /// `icon` is the app's own unless given: tests, which run outside the app, pass the icon file.
  public init(model: AppModel, icon: NSImage? = nil) {
    self.model = model
    self.icon = icon ?? NSApp.applicationIconImage
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, MenuMetrics.rowPadding)
        .padding(.bottom, 12)
      steps
      MenuSeparator()
      footer
        .padding(.horizontal, MenuMetrics.rowPadding)
    }
    .padding(14)
    .frame(width: 400, alignment: .leading)
    // For the Help links beside each step.
    .environment(model)
    .task { await model.watchWhileWelcomeOpen() }
    .onDisappear { model.welcomeClosed() }
  }

  private var header: some View {
    HStack(spacing: 14) {
      Image(nsImage: icon)
        .resizable()
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("Welcome to Ferry", bundle: .module)
          .font(.title2.weight(.semibold))
          .accessibilityAddTraits(.isHeader)
        Text("Ferry puts the files on your Android device in Finder.", bundle: .module)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var steps: some View {
    let lines = model.welcomeSteps
    ForEach(lines, id: \.step) { line in
      WelcomeStepRow(line: line, model: model)
    }
    if model.isWelcomeComplete {
      StatusRow(
        symbol: "checkmark.circle.fill", tint: .green,
        title: Text("Ferry is ready", bundle: .module)
      ) {
        Text("Your device is in Finder's sidebar, under Locations.", bundle: .module)
      } actions: {
        EmptyView()
      }
      .accessibilityElement(children: .combine)
    } else if lines.allSatisfy(\.isDone) {
      // The agent has not answered yet, or Finder has no location to turn on yet.
      StatusRow(symbol: "ellipsis.circle", title: Text("Checking…", bundle: .module))
    }
  }

  private var footer: some View {
    HStack(alignment: .firstTextBaseline) {
      Text("You can open this again from Help.", bundle: .module)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      if model.isWelcomeComplete {
        Button {
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Done", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      } else {
        Button {
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Not Now", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
      }
    }
  }
}

/// One step: done, a tick and its title; still needed, its symbol, title, what to do, the rows
/// that do it and its Help link.
private struct WelcomeStepRow: View {
  let line: WelcomeStepLine
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    if line.isDone {
      StatusRow(symbol: "checkmark.circle.fill", tint: .green, title: Text(title))
        .accessibilityElement(children: .combine)
        .accessibilityValue(Text("Done", bundle: .module))
    } else {
      needed.accessibilityElement(children: .contain)
    }
  }

  private var title: LocalizedStringResource {
    switch line.step {
    case .connectDevice: LocalizedStringResource("Connect a device", bundle: .module)
    case .turnOnInFinder: MenuStatusText.turnOnInFinder
    case .getPlatformTools: LocalizedStringResource("Get Android Platform Tools", bundle: .module)
    }
  }

  @ViewBuilder private var needed: some View {
    switch line.step {
    case .connectDevice:
      StatusRow(
        symbol: "cable.connector", title: Text(title), helpTopic: line.step.helpTopic
      ) {
        Text(
          "Connect it to the Mac with a USB cable, then choose Transfer files on it.",
          bundle: .module)
      } actions: {
        StatusAction(title: Text("How to Turn On File Transfer", bundle: .module)) {
          openGuide(.fileTransfer)
        }
        StatusAction(title: Text("How to Turn On USB Debugging", bundle: .module)) {
          openGuide(.usbDebugging)
        }
      }
    case .turnOnInFinder:
      StatusRow(symbol: "folder", title: Text(title), helpTopic: line.step.helpTopic) {
        Text("In Login Items & Extensions, turn on Ferry under File Providers.", bundle: .module)
      } actions: {
        StatusAction(title: Text("Open System Settings", bundle: .module)) {
          model.turnOnInFinder()
        }
      }
    case .getPlatformTools:
      platformTools
    }
  }

  /// The offer, worded as an optional step; a download under way or failed shows as in the menu.
  @ViewBuilder private var platformTools: some View {
    if let line = model.platformToolsRow, line != .offer {
      GetADBRow(line: line, model: model)
    } else {
      StatusRow(symbol: "shippingbox", title: Text(title), helpTopic: self.line.step.helpTopic) {
        Text(
          """
          Optional. USB debugging, Wi-Fi and a device's tools need adb, which Ferry downloads \
          from Google once.
          """, bundle: .module)
      } actions: {
        StatusAction(title: Text("Get Android Platform Tools…", bundle: .module)) {
          NSApp.activate()
          openWindow(id: PlatformToolsLicenseView.windowID)
        }
      }
    }
  }

  private func openGuide(_ topic: GuideTopic) {
    model.showWelcomeGuide(topic: topic)
    _ = model.takeGuideOpenRequest()
    NSApp.activate()
    openWindow(id: SetupGuide.windowID)
  }
}

/// Brings the welcome window forward when the model asks. On the menu-bar icon, which exists
/// from launch, so the first run's welcome opens without the menu; on the menu too.
struct WelcomePresenter: ViewModifier {
  @Environment(\.openWindow) private var openWindow
  let model: AppModel

  func body(content: Content) -> some View {
    content.onChange(of: model.welcome.openPending, initial: true) { _, _ in
      if model.takeWelcomeOpenRequest() {
        NSApp.activate()
        openWindow(id: WelcomeView.windowID)
      }
    }
  }
}

extension View {
  /// Opens the welcome window whenever `model` asks for it.
  public func presentsWelcome(_ model: AppModel) -> some View {
    modifier(WelcomePresenter(model: model))
  }
}

#Preview("First run") {
  let model = AppModel.preview([], provider: .noDomains, adb: .notInstalled)
  model.showWelcome()
  return WelcomeView(model: model)
}
