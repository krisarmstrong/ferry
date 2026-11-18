import FerryIPC
import FerryUI
import SwiftUI

/// The menu-bar app: registers the agent, shows its devices, and hosts the setup guide, Help
/// and Settings.
@main
struct FerryApp: App {
  @State private var model: AppModel

  init() {
    let model = AppModel(
      client: AgentClient(machServiceName: "X6JWYP43HG.io.github.krisarmstrong.ferry.agent"),
      services: SystemServices())
    _model = State(initialValue: model)
    // Registers the agent and reads the status once, so the log shows the devices before the
    // menu first opens. The system calls run off the main thread.
    Task { await model.launch() }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model)
    } label: {
      Image("MenuBarGlyph")
        .accessibilityLabel(Text("Ferry"))
    }
    .menuBarExtraStyle(.window)

    Window(SetupGuide.windowTitle, id: SetupGuide.windowID) {
      SetupGuide(model: model)
    }
    .windowResizability(.contentSize)
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    // Not restored at launch, like the setup guide; HelpView remembers the last section itself.
    Window(HelpView.windowTitle, id: HelpView.windowID) {
      HelpView(model: model)
    }
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)

    Settings {
      SettingsView(model: model)
    }
  }
}
