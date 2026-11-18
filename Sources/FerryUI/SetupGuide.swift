import SwiftUI

/// "Set up your device": the numbered steps for file transfer or USB debugging on the chosen
/// device family, with a picker for the model. Shown in its own window, because a sheet on the
/// menu-bar window closes with it.
public struct SetupGuide: View {
  public static let windowID = "setup-guide"
  public static let windowTitle = Text("Set Up Your Device", bundle: .module)

  @Environment(\.dismissWindow) private var dismissWindow
  @Bindable private var model: AppModel

  public init(model: AppModel) {
    self.model = model
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Picker(selection: $model.guideTopic) {
        ForEach(GuideTopic.allCases, id: \.self) { topic in
          Text(topic.title)
            .tag(topic)
        }
      } label: {
        Text("Set up", bundle: .module)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
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
        NumberedSteps(steps: GuideSteps.steps(for: family, topic: model.guideTopic))
        if model.guideTopic == .usbDebugging, let note = GuideSteps.debuggingNote(for: family) {
          Text(note)
            .font(.callout)
        }
      } else {
        Text("Choose your device to see its steps.", bundle: .module)
          .foregroundStyle(.secondary)
      }
      switch model.guideTopic {
      case .fileTransfer:
        Text("The device appears in Finder once it shares files.", bundle: .module)
          .font(.callout)
          .foregroundStyle(.secondary)
      case .usbDebugging:
        Text(
          "Ferry switches to ADB as soon as you allow this Mac on the device.", bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
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

/// Steps as a numbered list, the number in secondary monospaced digits. The setup guide and
/// the help window share it.
struct NumberedSteps: View {
  let steps: [LocalizedStringResource]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("\(index + 1).", bundle: .module)
            .monospacedDigit()
            .foregroundStyle(.secondary)
          Text(AttributedString(localized: step))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}

#Preview("NetAlly") {
  let model = AppModel.preview([])
  model.showGuide(for: PreviewClient.notSharing)
  return SetupGuide(model: model)
}

#Preview("USB debugging") {
  let model = AppModel.preview([])
  model.showUSBDebuggingGuide(for: PreviewClient.ready)
  return SetupGuide(model: model)
}

#Preview("Model picker") {
  SetupGuide(model: .preview([]))
}
