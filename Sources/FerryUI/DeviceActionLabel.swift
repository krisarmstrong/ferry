import SwiftUI

extension View {
  /// Names the device in what VoiceOver reads for a button each device row repeats (see
  /// `DevicePresentation.actionLabel(_:on:)`).
  func deviceAction(_ action: LocalizedStringResource, on name: String) -> some View {
    accessibilityLabel(Text(verbatim: DevicePresentation.actionLabel(action, on: name)))
  }
}
