import FerryIPC
import FerryUI
import SwiftUI

/// The menu-bar app: registers the agent, shows its devices, and hosts the setup guide and
/// Settings.
@main
struct FerryApp: App {
  @State private var model: AppModel

  init() {
    let services = SystemServices()
    services.registerAgent()
    let model = AppModel(
      client: AgentClient(machServiceName: "X6JWYP43HG.io.github.krisarmstrong.ferry.agent"),
      services: services)
    _model = State(initialValue: model)
    // One status request at launch, so the log shows the devices before the menu first opens.
    Task { await model.refresh() }
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

    Settings {
      SettingsView(model: model)
    }
  }
}
