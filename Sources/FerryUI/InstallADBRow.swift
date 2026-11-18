import SwiftUI

/// adb is not installed. Ferry never installs it: the row gives the command, to copy and run.
struct InstallADBRow: View {
  let copy: () -> Void
  let checkAgain: () -> Void
  @State private var copied = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("Install adb for more tools…", bundle: .module)
          .font(.headline)
      } icon: {
        Image(systemName: "terminal")
      }
      Text(verbatim: DevicePresentation.installCommand)
        .font(.callout.monospaced())
        .textSelection(.enabled)
        .foregroundStyle(.secondary)
      HStack {
        Button {
          copy()
          copied = true
        } label: {
          Text(copied ? "Copied" : "Copy", bundle: .module)
        }
        .help(Text("Copy the install command", bundle: .module))
        .task(id: copied) {
          guard copied else { return }
          try? await Task.sleep(for: .seconds(2))
          copied = false
        }
        Button(action: checkAgain) {
          Text("Check again", bundle: .module)
        }
      }
    }
    .accessibilityElement(children: .contain)
  }
}

/// adb is installed but its server does not answer.
struct ADBNotRunningRow: View {
  let checkAgain: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text("adb isn't running", bundle: .module)
          .font(.headline)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.yellow)
      }
      Button(action: checkAgain) {
        Text("Check again", bundle: .module)
      }
    }
    .accessibilityElement(children: .contain)
  }
}
