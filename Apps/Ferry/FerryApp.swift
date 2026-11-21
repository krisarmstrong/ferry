import FerryIPC
import FerryUI
import SwiftUI

/// The menu-bar app: registers the agent, shows its devices, and hosts the welcome, the setup
/// guide, Help and the developer tools' windows. Ferry has no Settings window: Open at Login is in the menu,
/// Remove Ferry… in Help.
@main
struct FerryApp: App {
  @State private var model: AppModel

  init() {
    // The build records the signing team in Info.plist; `make app` checks it is there.
    guard let identity = FerryIdentity() else {
      preconditionFailure("FerryTeamID is missing from Ferry's Info.plist")
    }
    let model = AppModel(client: AgentClient(identity: identity), services: SystemServices())
    model.updater = SparkleUpdates()
    _model = State(initialValue: model)
    // Registers the agent and reads the status once, so the log shows the devices before the
    // menu first opens. The system calls run off the main thread.
    Task { await model.launch() }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      // The icon exists from launch, so it opens the first run's welcome (see WelcomeView).
      Image("MenuBarGlyph")
        .accessibilityLabel(Text(verbatim: "Ferry"))
        .presentsWelcome(model)
    }
    .menuBarExtraStyle(.window)

    // Shown once, on a Mac new to Ferry, and from Help.
    Window(WelcomeView.windowTitle, id: WelcomeView.windowID) {
      WelcomeView(model: model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Window(SetupGuide.windowTitle, id: SetupGuide.windowID) {
      SetupGuide(model: model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    // Google's license, shown before Ferry downloads adb.
    Window(PlatformToolsLicenseView.windowTitle, id: PlatformToolsLicenseView.windowID) {
      PlatformToolsLicenseView(model: model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    // Not restored at launch, like the setup guide; HelpView remembers the last topic itself.
    Window(HelpView.windowTitle, id: HelpView.windowID) {
      HelpView(model: model)
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    DeveloperScenes(model: model)
  }
}
