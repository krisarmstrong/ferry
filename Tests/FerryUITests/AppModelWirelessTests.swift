import DeviceKit
import FerryIPC
import Foundation
import Testing

@testable import FerryUI

@MainActor
struct AppModelWirelessTests {
  let log = CallLog()

  private func model(_ client: FakeClient) -> AppModel {
    AppModel(client: client, services: FakeServices(log: log))
  }

  /// Types into the form and sends it, as the menu does. Returns whether the form closed.
  private func send(
    _ model: AppModel, _ kind: WirelessForm, address: String, code: String = ""
  ) async -> Bool {
    model.toggleNetworkForm(kind)
    model.networkForm?.address = address
    model.networkForm?.code = code
    await model.submitNetworkForm()
    return model.networkForm == nil
  }

  static let etherScope = RememberedDevice(
    id: DeviceID(serial: "fedcba9876543210"), name: "EtherScope nXG",
    addresses: [WirelessEndpoint(parsing: "192.0.2.31")!])

  /// A device on Wi-Fi shows the address Ferry last reached it at; one Ferry has no address for
  /// shows none.
  @Test func aWiFiDeviceIsShownAtItsRememberedAddress() async {
    let client = FakeClient(log: log)
    client.setStatus(
      [device(Self.etherScope.id.serial, model: "EtherScope nXG", .ready([]), method: .wifiADB)],
      remembered: [Self.etherScope])
    let model = model(client)
    await model.refresh()
    #expect(model.wirelessAddress(of: Self.etherScope.id) == Self.etherScope.addresses.first)
    #expect(model.wirelessAddress(of: DeviceID(serial: "other")) == nil)
  }

  /// adb's own address for the connection wins over the remembered ones, which can be stale.
  @Test func aWiFiDeviceIsShownAtTheAddressAdbConnectedOn() async throws {
    let connected = try #require(WirelessEndpoint(parsing: "192.0.2.77:37123"))
    let client = FakeClient(log: log)
    client.setStatus(
      [device(Self.etherScope.id.serial, model: "EtherScope nXG", .ready([]), method: .wifiADB)],
      remembered: [Self.etherScope], connectedAddresses: [Self.etherScope.id: connected])
    let model = model(client)
    await model.refresh()
    #expect(model.wirelessAddress(of: Self.etherScope.id) == connected)
  }

  @Test func connectByAddressSendsTheValidatedAddress() async {
    let client = FakeClient(log: log)
    let model = model(client)
    #expect(await send(model, .address, address: "192.0.2.31") == true)
    #expect(log.all == ["connectAddress 192.0.2.31:5555", "status"])
    #expect(model.wirelessMessage == nil)
  }

  /// The form checks before anything reaches the agent, which checks again.
  @Test(arguments: ["", "-s", "192.0.2.31:0", "a b"])
  func anAddressThatIsNotOneSendsNothing(text: String) async {
    let client = FakeClient(log: log)
    let model = model(client)
    #expect(await send(model, .address, address: text) == false)
    #expect(log.all.isEmpty)
  }

  @Test func pairingNeedsAPortAndSixDigits() async {
    func canSend(_ address: String, _ code: String) -> Bool {
      NetworkForm(kind: .code, address: address, code: code).canSend
    }
    #expect(canSend("192.0.2.170:37123", "482913"))
    #expect(!canSend("192.0.2.170", "482913"))
    #expect(!canSend("192.0.2.170:37123", "48291"))
    #expect(!canSend("pixel.lan:37123", "482913"))
    let client = FakeClient(log: log)
    let model = model(client)
    #expect(await send(model, .code, address: "192.0.2.170:37123", code: "482913") == true)
    #expect(log.all.first == "pair 192.0.2.170:37123 482913")
  }

  /// Waiting for Allow is a step for the user, not a failure: the form closes and the menu shows
  /// the waiting line.
  @Test func awaitingAllowIsDoneWithAMessage() async throws {
    let client = FakeClient(log: log)
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.31"))
    client.setWireless(.wireless(.awaitingAllow(address)))
    let model = model(client)
    #expect(await send(model, .address, address: "192.0.2.31") == true)
    #expect(model.wirelessMessage?.text == "Tap Allow on the device to finish connecting.")
  }

  @Test(arguments: [
    (
      WirelessOutcome.needsNetwork,
      "The device has no network address. Connect it to Ethernet or Wi-Fi first."
    ),
    (
      .failed(.adb("failed to connect to '192.0.2.99:5555': Connection refused")),
      "adb refused the request. Check the address and that the device is on the network, then "
        + "try again. (failed to connect to '192.0.2.99:5555': Connection refused)"
    ),
    (
      .failed(.adb("bad\u{202E}text")),
      "adb refused the request. Check the address and that the device is on the network, then "
        + "try again. (bad\\u{202E}text)"
    ),
    (.failed(.otherDevice), "That address belongs to another device."),
  ])
  func failuresKeepTheFormOpenWithAReason(outcome: WirelessOutcome, message: String) async {
    let client = FakeClient(log: log)
    client.setWireless(.wireless(outcome))
    let model = model(client)
    #expect(await send(model, .address, address: "192.0.2.99") == false)
    #expect(model.networkForm?.message?.text == message)
    #expect(model.networkForm?.message?.help != nil)
  }

  @Test func useOverWiFiAndForgetAndConnectAgainReachTheAgent() async {
    let client = FakeClient(log: log)
    let model = model(client)
    await model.useOverWiFi(DeviceID(serial: "A1"))
    await model.connectAgain(Self.etherScope.id)
    await model.forget(Self.etherScope.id)
    #expect(
      log.all == [
        "enableWireless A1", "status", "connectWireless fedcba9876543210", "status",
        "forgetWireless fedcba9876543210", "status",
      ])
  }

  /// A remembered device that is not attached gets its own row, with Connect and Forget; one
  /// that is attached is forgotten from its device row.
  @Test func rememberedDevicesNotAttachedAreListedApart() async {
    let client = FakeClient(log: log)
    let other = RememberedDevice(
      id: DeviceID(serial: "LR1"), name: "LinkRunner", addresses: [])
    client.setStatus(
      [device("fedcba9876543210", model: "EtherScope nXG", .ready([]), method: .wifiADB)],
      remembered: [Self.etherScope, other])
    let model = model(client)
    await model.refresh()
    #expect(model.isRemembered(Self.etherScope.id))
    #expect(model.rememberedOffline == [other])
  }

  @Test func useOverWiFiIsOfferedOnAReadyUSBADBDevice() {
    #expect(
      DevicePresentation.offersWiFi(device("A1", model: "LinkRunner", .ready([]), method: .usbADB)))
    #expect(
      !DevicePresentation.offersWiFi(
        device("A1", model: "LinkRunner", .ready([]), method: .usbFileTransfer)))
    #expect(
      !DevicePresentation.offersWiFi(
        device("A1", model: "LinkRunner", .ready([]), method: .wifiADB)))
    #expect(
      !DevicePresentation.offersWiFi(device("A1", model: "LinkRunner", .ejected, method: .usbADB)))
  }

  /// The remembered name came from the device: shown escaped.
  @Test func rememberedNamesAreEscaped() {
    let hostile = RememberedDevice(
      id: DeviceID(serial: "X"), name: "Evil\u{202E}gpj", addresses: [])
    #expect(DevicePresentation.rememberedName(hostile) == "Evil\\u{202E}gpj")
  }

  /// A new address for a device Ferry knows waits for the user: the menu asks, and only Use It
  /// or Ignore answers.
  @Test func unconfirmedAddressesAreAskedAboutAndAnswered() async throws {
    let client = FakeClient(log: log)
    let address = try #require(WirelessEndpoint(parsing: "192.0.2.99"))
    let offer = UnconfirmedAddress(address: address, id: Self.etherScope.id, name: "EtherScope nXG")
    client.setStatus([], unconfirmed: [offer])
    client.setWireless(.wireless(.needsConfirmation(address)))
    let model = model(client)
    #expect(await send(model, .address, address: "192.0.2.99") == true)
    #expect(model.unconfirmed == [offer])
    #expect(DevicePresentation.confirmQuestion(offer) == "Is 192.0.2.99:5555 your EtherScope nXG?")
    await model.confirm(offer)
    await model.ignore(address)
    #expect(
      log.all == [
        "connectAddress 192.0.2.99:5555", "status",
        "confirmWireless 192.0.2.99:5555 fedcba9876543210 EtherScope nXG",
        "status",
        "ignoreWireless 192.0.2.99:5555", "status",
      ])
  }
}
