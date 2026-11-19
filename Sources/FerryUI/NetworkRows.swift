import DeviceKit
import FerryIPC
import SwiftUI

/// A device Ferry reconnects over the network that is not attached now: a neutral tile, and
/// Connect Again and Forget in its expansion.
struct RememberedRow: View {
  let device: RememberedDevice
  let isExpanded: Bool
  let toggle: () -> Void
  let connect: () -> Void
  let forget: () -> Void
  private var name: String { DevicePresentation.rememberedName(device) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandingRowHeader(
        tile: DevicePresentation.rememberedTile, name: name,
        summary: DevicePresentation.rememberedSummary, isExpanded: isExpanded, toggle: toggle)
      if isExpanded {
        ForEach(DevicePresentation.rememberedActions, id: \.self) { action in
          MenuRow(
            title: Text(action.title), symbol: action.symbol, indent: MenuMetrics.actionIndent,
            action: action == .connectAgain ? connect : forget
          )
          .deviceAction(action.title, on: name)
        }
      }
    }
  }
}

/// "Is <address> your <model>?": an address that claims a device Ferry knows, which Ferry will
/// not use until the user says so. Use It and Ignore are in its expansion.
struct UnconfirmedRow: View {
  let offer: UnconfirmedAddress
  let isExpanded: Bool
  let toggle: () -> Void
  let confirm: () -> Void
  let ignore: () -> Void
  private var name: String { DevicePresentation.offerName(offer) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ExpandingRowHeader(
        tile: DevicePresentation.offerTile, name: name,
        summary: DevicePresentation.offerSummary(offer), isExpanded: isExpanded, toggle: toggle)
      if isExpanded {
        Text(verbatim: DevicePresentation.confirmQuestion(offer))
          .font(.callout)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, MenuMetrics.rowPadding + MenuMetrics.actionIndent)
          .padding(.trailing, MenuMetrics.rowPadding)
          .padding(.bottom, 2)
        ForEach(DevicePresentation.offerActions, id: \.self) { action in
          MenuRow(
            title: Text(action.title), symbol: action.symbol, indent: MenuMetrics.actionIndent,
            action: action == .useIt ? confirm : ignore
          )
          .deviceAction(action.title, on: name)
        }
      }
    }
  }
}
