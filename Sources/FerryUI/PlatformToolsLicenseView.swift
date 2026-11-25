import PlatformTools
import SwiftUI

/// Google's Android SDK License, which the user accepts before Ferry downloads the platform tools.
/// The text is Google's, bundled and shown as it is: its version and checksum are pinned with the
/// release (`PlatformToolsRelease.license`).
public struct PlatformToolsLicenseView: View {
  public static let windowID = "android-sdk-license"
  public static let windowTitle = Text("Android SDK License", bundle: .module)

  static let licenseText: String? = Bundle.module
    .url(forResource: "android-sdk-license", withExtension: "txt")
    .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

  private let model: AppModel
  @Environment(\.dismissWindow) private var dismissWindow

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        """
        To get adb, Ferry downloads Android SDK Platform-Tools \(PlatformToolsRelease.pinned.version) \
        from Google, which licenses it under these terms.
        """, bundle: .module
      )
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        Text(verbatim: Self.licenseText ?? "")
          .font(.callout)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
      }
      .background(.background.secondary, in: .rect(cornerRadius: 6))
      HStack {
        Spacer()
        Button {
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          model.acceptLicense()
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Accept", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(Self.licenseText == nil)
      }
    }
    .padding(20)
    // Resizable (L8): the licence scrolls, and the buttons stay below it at any size.
    .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 520)
  }
}
