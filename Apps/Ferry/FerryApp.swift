import ServiceManagement
import SwiftUI
import os

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "App")

/// The menu-bar app. A placeholder until the status menu lands: it registers the agent and
/// offers Quit.
@main
struct FerryApp: App {
  init() {
    Self.registerAgent()
  }

  var body: some Scene {
    MenuBarExtra("Ferry", systemImage: "externaldrive.connected.to.line.below") {
      Button("Quit Ferry") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
  }

  private static func registerAgent() {
    let agent = SMAppService.agent(plistName: "io.github.krisarmstrong.ferry.agent.plist")
    do {
      try agent.register()
    } catch {
      log.error("registering the agent failed: \(error, privacy: .public)")
    }
    log.info("agent status: \(describe(agent.status), privacy: .public)")
  }

  private static func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "notRegistered"
    case .enabled: "enabled"
    case .requiresApproval: "requiresApproval"
    case .notFound: "notFound"
    @unknown default: "unknown (\(status.rawValue))"
    }
  }
}
