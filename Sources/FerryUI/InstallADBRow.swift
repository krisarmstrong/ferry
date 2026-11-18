import SwiftUI

/// adb is not installed. Ferry never installs it: the row gives the command, to copy and run.
struct InstallADBRow: View {
  let copy: () -> Void
  let checkAgain: () -> Void

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
        Button(action: copy) {
          Text("Copy", bundle: .module)
        }
        Button(action: checkAgain) {
          Text("Check again", bundle: .module)
        }
      }
    }
  }
}
