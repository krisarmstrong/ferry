import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row offers for the network: Use over Wi-Fi on a device on USB debugging, and
/// Forget on one Ferry reconnects over the network.
struct NetworkActions {
  /// The device as the menu names it, for VoiceOver.
  let name: String
  let offersWiFi: Bool
  let isRemembered: Bool
  let useOverWiFi: () -> Void
  let forget: () -> Void
}

/// A device row's network buttons.
struct NetworkButtons: View {
  let actions: NetworkActions

  var body: some View {
    if actions.offersWiFi {
      Button(action: actions.useOverWiFi) {
        Text("Use over Wi-Fi", bundle: .module)
      }
      .deviceAction(LocalizedStringResource("Use over Wi-Fi", bundle: .module), on: actions.name)
    }
    if actions.isRemembered {
      Button(action: actions.forget) {
        Text("Forget", bundle: .module)
      }
      .deviceAction(LocalizedStringResource("Forget", bundle: .module), on: actions.name)
    }
  }
}

/// A device Ferry reconnects over the network that is not attached now.
struct RememberedRow: View {
  let device: RememberedDevice
  let connect: () -> Void
  let forget: () -> Void
  private var name: String { DevicePresentation.rememberedName(device) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: name)
            .font(.headline)
          Text(verbatim: "·")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          Text("Not connected", bundle: .module)
            .foregroundStyle(.secondary)
        }
        .lineLimit(1)
      } icon: {
        Image(systemName: "wifi")
      }
      HStack {
        Button(action: connect) {
          Text("Connect", bundle: .module)
        }
        .deviceAction(LocalizedStringResource("Connect", bundle: .module), on: name)
        Spacer()
        Button(action: forget) {
          Text("Forget", bundle: .module)
        }
        .deviceAction(LocalizedStringResource("Forget", bundle: .module), on: name)
      }
    }
  }
}

/// What the last network request said, and the two ways onto the network adb offers.
struct NetworkRow: View {
  let message: String?
  let offersForms: Bool
  let open: (WirelessForm) -> Void

  var body: some View {
    if let message {
      Text(verbatim: message)
        .font(.callout)
        .foregroundStyle(.secondary)
    }
    if offersForms {
      HStack {
        Button {
          open(.address)
        } label: {
          Text("Connect by Address…", bundle: .module)
        }
        Button {
          open(.code)
        } label: {
          Text("Pair with Code…", bundle: .module)
        }
      }
    }
  }
}

/// "Is <address> your <model>?": an address that claims a device Ferry knows, which Ferry will
/// not use until the user says so.
struct UnconfirmedRow: View {
  let offer: UnconfirmedAddress
  let confirm: () -> Void
  let ignore: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        Text(verbatim: DevicePresentation.confirmQuestion(offer))
          .font(.callout)
      } icon: {
        Image(systemName: "questionmark.circle")
      }
      HStack {
        Button(action: confirm) {
          Text("Use It", bundle: .module)
        }
        Button(action: ignore) {
          Text("Ignore", bundle: .module)
        }
      }
    }
  }
}
