import DeviceKit
import FerryIPC
import SwiftUI

/// What a device row offers for the network: Use over Wi-Fi on a device on USB debugging, and
/// Forget on one Ferry reconnects over the network.
struct NetworkActions {
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
    }
    if actions.isRemembered {
      Button(action: actions.forget) {
        Text("Forget", bundle: .module)
      }
    }
  }
}

/// A device Ferry reconnects over the network that is not attached now.
struct RememberedRow: View {
  let device: RememberedDevice
  let connect: () -> Void
  let forget: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label {
        HStack(spacing: 4) {
          Text(verbatim: DevicePresentation.rememberedName(device))
            .font(.headline)
          Text(verbatim: "·")
            .foregroundStyle(.secondary)
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
        Spacer()
        Button(action: forget) {
          Text("Forget", bundle: .module)
        }
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
