import SwiftUI

/// adb is not installed. Ferry never installs it: the row gives the command, to copy and run.
struct InstallADBRow: View {
  let copy: () -> Void
  let checkAgain: () -> Void
  @State private var copied = false

  var body: some View {
    StatusRow(symbol: "terminal", title: Text("Install adb for more tools…", bundle: .module)) {
      Text(verbatim: DevicePresentation.installCommand)
        .font(.callout.monospaced())
        .textSelection(.enabled)
    } actions: {
      StatusAction(title: Text(copied ? "Copied" : "Copy", bundle: .module)) {
        copy()
        copied = true
      }
      .help(Text("Copy the install command", bundle: .module))
      .task(id: copied) {
        guard copied else { return }
        try? await Task.sleep(for: .seconds(2))
        copied = false
      }
      StatusAction(title: Text("Check Again", bundle: .module), action: checkAgain)
    }
    .accessibilityElement(children: .contain)
  }
}

/// adb is installed but its server does not answer.
struct ADBNotRunningRow: View {
  let checkAgain: () -> Void

  var body: some View {
    StatusRow(
      symbol: "exclamationmark.triangle", tint: .yellow,
      title: Text("adb isn't running", bundle: .module)
    ) {
      StatusAction(title: Text("Check Again", bundle: .module), action: checkAgain)
    }
    .accessibilityElement(children: .contain)
  }
}
