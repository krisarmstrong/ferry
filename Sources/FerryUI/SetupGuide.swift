import SwiftUI

/// "Turn on file transfer": the numbered steps for the chosen device family, with a picker for
/// the model. Shown in its own window, because a sheet on the menu-bar window closes with it.
public struct SetupGuide: View {
  public static let windowID = "setup-guide"
  public static let windowTitle = Text("Turn On File Transfer", bundle: .module)

  @Environment(\.dismissWindow) private var dismissWindow
  @Bindable private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker(selection: $model.guideFamily) {
        Text("Choose your device", bundle: .module)
          .tag(DeviceFamily?.none)
        ForEach(DeviceFamily.allCases, id: \.self) { family in
          Text(family.title)
            .tag(DeviceFamily?.some(family))
        }
      } label: {
        Text("Device", bundle: .module)
      }
      if let family = model.guideFamily {
        VStack(alignment: .leading, spacing: 10) {
          let steps = Array(GuideSteps.steps(for: family).enumerated())
          ForEach(steps, id: \.offset) { index, step in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text("\(index + 1).", bundle: .module)
                .monospacedDigit()
                .foregroundStyle(.secondary)
              Text(AttributedString(localized: step))
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      } else {
        Text("Choose your device to see its steps.", bundle: .module)
          .foregroundStyle(.secondary)
      }
      Text("The device appears in Finder once it shares files.", bundle: .module)
        .font(.callout)
        .foregroundStyle(.secondary)
      HStack {
        Spacer()
        Button {
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Done", bundle: .module)
        }
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 460)
    .onDisappear { model.isGuidePresented = false }
  }
}

#Preview("NetAlly") {
  let model = AppModel.preview([])
  model.showGuide(for: PreviewClient.notSharing)
  return SetupGuide(model: model)
}

#Preview("Model picker") {
  SetupGuide(model: .preview([]))
}
