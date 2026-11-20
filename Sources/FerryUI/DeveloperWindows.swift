import DeviceKit
import SwiftUI

/// The scenes of the developer tools' windows, for the app's `body`: Logcat, a window group over
/// the device, so two devices have two windows and opening one again brings it forward.
public struct DeveloperScenes: Scene {
  private let model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some Scene {
    WindowGroup(LogcatWindow.windowTitle, id: LogcatWindow.windowID, for: DeviceID.self) {
      logcat($0.wrappedValue)
    }
    .defaultSize(width: 900, height: 560)
    .commandsRemoved()
    .defaultLaunchBehavior(.suppressed)
    .restorationBehavior(.disabled)
  }

  // A window the system restored without its device has nothing to show.
  @ViewBuilder private func logcat(_ device: DeviceID?) -> some View {
    if let device { LogcatWindow(model: model, device: device) }
  }
}
