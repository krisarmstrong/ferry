import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

/// Connect by Address… and Pair with Code… open in place under the network rows: one at a time,
/// with what was typed kept on the model, progress and errors in the form, and collapsing or
/// Escape cancelling it.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AppModelNetworkFormTests {
  let log = CallLog()
  let client: FakeClient

  init() {
    client = FakeClient(log: log)
  }

  private func model() -> AppModel {
    AppModel(client: client, services: FakeServices(log: log), sleep: { _ in })
  }

  @Test func oneFormIsOpenAtATime() {
    let model = model()
    #expect(model.networkForm == nil)
    model.toggleNetworkForm(.address)
    #expect(model.networkForm?.kind == .address)
    model.networkForm?.address = "192.0.2.31"
    model.toggleNetworkForm(.code)
    #expect(model.networkForm?.kind == .code)
    #expect(model.networkForm?.address == "")
    model.toggleNetworkForm(.code)
    #expect(model.networkForm == nil)
    #expect(log.all.isEmpty)
  }

  /// The form shows only its own answers: what Use over Wi-Fi says stays in the status row, a
  /// form open or not.
  @Test func messagesFromElsewhereStayInTheStatusRow() async {
    client.setWireless(.wireless(.needsNetwork))
    let model = model()
    await model.useOverWiFi(DeviceID(serial: "A1"))
    let message = model.wirelessMessage
    #expect(message != nil)
    model.toggleNetworkForm(.address)
    #expect(model.wirelessMessage == message)
    #expect(model.networkForm?.message == nil)
    await model.useOverWiFi(DeviceID(serial: "A1"))
    #expect(model.wirelessMessage == message)
    #expect(model.networkForm?.message == nil)
  }

  @Test(arguments: [
    (WirelessForm.address, "192.0.2.31", "", true), (.address, "", "", false),
    (.address, "a b", "", false), (.code, "192.0.2.31:37123", "482913", true),
    (.code, "192.0.2.31", "482913", false), (.code, "192.0.2.31:37123", "4829", false),
  ])
  func sendWaitsForAnAddressAndACode(
    kind: WirelessForm, address: String, code: String, sendable: Bool
  ) {
    let model = model()
    model.toggleNetworkForm(kind)
    model.networkForm?.address = address
    model.networkForm?.code = code
    #expect(model.networkForm?.canSend == sendable)
  }

  /// A failure keeps the form, what was typed and the reason, which is the form's alone.
  @Test func aFailureKeepsTheFormWithItsReason() async {
    client.setWireless(.wireless(.failed(.otherDevice)))
    let model = model()
    model.toggleNetworkForm(.address)
    model.networkForm?.address = "192.0.2.99"
    await model.submitNetworkForm()
    #expect(model.networkForm?.address == "192.0.2.99")
    #expect(model.networkForm?.isSending == false)
    #expect(model.networkForm?.message == "That address belongs to another device.")
    #expect(model.wirelessMessage == nil)
    // Typing again, or sending again, starts without the old reason.
    model.toggleNetworkForm(.address)
    model.toggleNetworkForm(.address)
    #expect(model.networkForm?.message == nil)
  }

  /// Waiting for Allow closes the form; the menu's status row then says what to do.
  @Test func doneClosesTheFormAndTheMenuShowsWhatFollows() async throws {
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31"))
    client.setWireless(.wireless(.awaitingAllow(address)))
    let model = model()
    model.toggleNetworkForm(.address)
    model.networkForm?.address = "192.0.2.31"
    await model.submitNetworkForm()
    #expect(model.networkForm == nil)
    #expect(model.wirelessMessage == "Tap Allow on the device to finish connecting.")
  }

  /// Collapsing the form while it sends cancels the request, and its answer is never shown.
  @Test(arguments: [true, false])
  func collapsingOrEscapeCancelsASendInFlight(collapse: Bool) async {
    client.wirelessPark.start()
    let model = model()
    model.toggleNetworkForm(.code)
    model.networkForm?.address = "192.0.2.31:37123"
    model.networkForm?.code = "482913"
    let send = Task { await model.submitNetworkForm() }
    for await _ in client.wirelessPark.arrivals { break }
    #expect(model.networkForm?.isSending == true)
    // A second Pair while one is on its way sends nothing.
    await model.submitNetworkForm()
    if collapse { model.toggleNetworkForm(.code) } else { model.closeNetworkForm() }
    await send.value
    #expect(model.networkForm == nil)
    #expect(model.wirelessMessage == nil)
    #expect(log.all.filter { $0.hasPrefix("pair") } == ["pair 192.0.2.31:37123 482913"])
    #expect(log.all.contains("wireless cancelled"))
  }

  /// What was typed is the model's: the menu's redraws and its closing keep it.
  @Test func typedTextSurvivesARefreshAndTheMenuOpeningAgain() async {
    let model = AppModel(
      client: client, services: FakeServices(log: log), sleep: { _ in throw CancellationError() })
    model.toggleNetworkForm(.code)
    model.networkForm?.address = "192.0.2.31:37123"
    await model.refresh()
    await model.watchWhileMenuOpen()
    #expect(model.networkForm?.kind == .code)
    #expect(model.networkForm?.address == "192.0.2.31:37123")
  }
}
