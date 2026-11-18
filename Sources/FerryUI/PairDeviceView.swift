import SwiftUI

/// Which network form the window shows.
public enum WirelessForm: Hashable, Sendable, CaseIterable {
  /// Connect by Address: the device already listens for adb (NetAlly units on 5555).
  case address
  /// Pair with Code: Android 11+ Wireless debugging.
  case code

  var title: LocalizedStringResource {
    switch self {
    case .address: LocalizedStringResource("Connect by Address", bundle: .module)
    case .code: LocalizedStringResource("Pair with Code", bundle: .module)
    }
  }
}

/// Connect by Address and Pair with Code, in a window of their own: a sheet on the menu-bar
/// window would close with it. Send stays off until the fields hold an address (and a code); the
/// agent checks them again. The window closes once connected or waiting for Allow on the
/// device, which the menu then shows.
public struct PairDeviceView: View {
  public static let windowID = "connect-over-network"
  public static let windowTitle = Text("Connect over the Network", bundle: .module)

  @Environment(\.dismissWindow) private var dismissWindow
  @Bindable private var model: AppModel
  @State private var address = ""
  @State private var pairingAddress = ""
  @State private var code = ""
  @State private var isSending = false

  public init(model: AppModel) {
    self.model = model
  }

  private var canSend: Bool {
    guard !isSending else { return false }
    return switch model.wirelessForm {
    case .address: AppModel.isValidAddress(address)
    case .code: AppModel.isValidPairing(address: pairingAddress, code: code)
    }
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Picker(selection: $model.wirelessForm) {
        ForEach(WirelessForm.allCases, id: \.self) { form in
          Text(form.title)
            .tag(form)
        }
      } label: {
        Text("Connect", bundle: .module)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      switch model.wirelessForm {
      case .address:
        TextField(text: $address, prompt: Text(verbatim: "10.0.0.20:5555")) {
          Text("Address", bundle: .module)
        }
        Text(
          "The device's IP address or name. Ferry uses port 5555 unless you add another.",
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      case .code:
        TextField(text: $pairingAddress, prompt: Text(verbatim: "10.0.0.20:37123")) {
          Text("IP address and port", bundle: .module)
        }
        TextField(text: $code, prompt: Text(verbatim: "123456")) {
          Text("Pairing code", bundle: .module)
        }
        Text(
          "On the device, open Wireless debugging and choose Pair device with pairing code.",
          bundle: .module
        )
        .font(.callout)
        .foregroundStyle(.secondary)
      }
      if let message = model.wirelessMessage {
        Text(verbatim: message)
          .font(.callout)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if isSending {
          ProgressView()
            .controlSize(.small)
        }
        Spacer()
        Button {
          dismissWindow(id: Self.windowID)
        } label: {
          Text("Cancel", bundle: .module)
        }
        .keyboardShortcut(.cancelAction)
        Button {
          Task { await send() }
        } label: {
          switch model.wirelessForm {
          case .address: Text("Connect", bundle: .module)
          case .code: Text("Pair", bundle: .module)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSend)
      }
    }
    .padding(20)
    .frame(width: 400)
    .onAppear { model.wirelessMessage = nil }
  }

  private func send() async {
    isSending = true
    defer { isSending = false }
    let done =
      switch model.wirelessForm {
      case .address: await model.connect(address: address)
      case .code: await model.pair(address: pairingAddress, code: code)
      }
    if done {
      code = ""
      dismissWindow(id: Self.windowID)
    }
  }
}

#Preview("Address") {
  PairDeviceView(model: .preview([]))
}

#Preview("Code") {
  let model = AppModel.preview([])
  model.wirelessForm = .code
  return PairDeviceView(model: model)
}
