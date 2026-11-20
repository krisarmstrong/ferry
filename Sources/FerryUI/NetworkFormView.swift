import SwiftUI

/// The two ways onto the network adb offers, as menu rows. Each opens its form in place under
/// it, one at a time; clicking the row again closes it.
struct NetworkFormRows: View {
  let model: AppModel

  var body: some View {
    row(.address, title: Text("Connect by Address…", bundle: .module))
    row(.code, title: Text("Pair with Code…", bundle: .module))
  }

  @ViewBuilder private func row(_ kind: WirelessForm, title: Text) -> some View {
    let isOpen = model.networkForm?.kind == kind
    MenuRow(title: title, isExpanded: isOpen) { model.toggleNetworkForm(kind) }
    if isOpen {
      NetworkFormView(model: model)
        .padding(.leading, MenuMetrics.rowPadding + MenuMetrics.symbolWidth + 8)
        .padding(.trailing, MenuMetrics.rowPadding)
        .padding(.bottom, 6)
    }
  }
}

/// Connect by Address (an address field and Connect) or Pair with Code (address and code
/// fields, and Pair). Send stays off until the fields hold an address (and a code); Return
/// sends, and Escape closes the form. While it sends a spinner shows; a reason it failed shows
/// under the fields in red.
struct NetworkFormView: View {
  private enum Field: Hashable {
    case address, code
  }

  @Bindable var model: AppModel
  @FocusState private var focused: Field?

  var body: some View {
    if let form = model.networkForm {
      VStack(alignment: .leading, spacing: 6) {
        fields(form.kind)
          .textFieldStyle(.roundedBorder)
          .controlSize(.small)
          .labelsHidden()
          // Not disabled while sending: a disabled field gives up focus, and Escape then never
          // reaches the form. A second send waits on `isSending` instead.
          .onSubmit { Task { await model.submitNetworkForm() } }
        hint(form.kind)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let message = form.message {
          HelpLinked(key: message.help) {
            Text(verbatim: message.text)
              .foregroundStyle(.red)
          }
        }
        HStack {
          if form.isSending {
            ProgressView()
              .controlSize(.small)
          }
          Spacer()
          Button {
            Task { await model.submitNetworkForm() }
          } label: {
            switch form.kind {
            case .address: Text("Connect", bundle: .module)
            case .code: Text("Pair", bundle: .module)
            }
          }
          .controlSize(.small)
          .disabled(!form.canSend)
        }
      }
      .font(.callout)
      .onAppear { focused = .address }
      .onExitCommand { model.closeNetworkForm() }
    }
  }

  @ViewBuilder private func fields(_ kind: WirelessForm) -> some View {
    switch kind {
    case .address:
      TextField(text: address, prompt: Text(verbatim: "10.0.0.20:5555")) {
        Text("Address", bundle: .module)
      }
      .focused($focused, equals: .address)
    case .code:
      TextField(text: address, prompt: Text(verbatim: "10.0.0.20:37123")) {
        Text("IP address and port", bundle: .module)
      }
      .focused($focused, equals: .address)
      TextField(text: code, prompt: Text(verbatim: "123456")) {
        Text("Pairing code", bundle: .module)
      }
      .focused($focused, equals: .code)
    }
  }

  @ViewBuilder private func hint(_ kind: WirelessForm) -> some View {
    switch kind {
    case .address:
      Text(
        "The device's IP address or name. Ferry uses port 5555 unless you add another.",
        bundle: .module)
    case .code:
      Text(
        "On the device, open Wireless debugging and choose Pair device with pairing code.",
        bundle: .module)
    }
  }

  private var address: Binding<String> {
    Binding(
      get: { model.networkForm?.address ?? "" }, set: { model.networkForm?.address = $0 })
  }

  private var code: Binding<String> {
    Binding(get: { model.networkForm?.code ?? "" }, set: { model.networkForm?.code = $0 })
  }
}
