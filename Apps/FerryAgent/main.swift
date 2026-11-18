import ADBTransport
import FerryAgentCore
import FerryIPC
import Foundation
import MTPTransport
import os

// The agent: the only process that touches USB. It owns the device sessions, keeps one
// FileProvider domain per storage, and serves the app and the extension on its Mach service.

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Agent")

// The team the build signed Ferry with, which names the Mach service and admits clients.
guard let identity = FerryIdentity() else {
  log.fault("FerryTeamID is missing from the agent's Info.plist")
  exit(EXIT_FAILURE)
}

let itemStore: URL
let wirelessStore: URL
do {
  itemStore = try DomainController.defaultItemStore()
  wirelessStore = try WirelessADB.defaultStore()
} catch {
  log.fault("no item store: \(error, privacy: .public)")
  exit(EXIT_FAILURE)
}

FileTransfer.sweep()

// MTP and the user's adb server together: each device is served by the best method it offers.
// What the network may serve, as WirelessADB decides; ADBTransport asks it on every scan. It
// serves no network route until WirelessADB below has loaded its store, so a scan the hub makes
// first cannot serve a connection the adb server kept from before this agent started.
let vouching = WirelessVouching()
let adb = ADBTransport(serving: { vouching.serves($0, as: $1) })
let hub = DeviceHub(
  transport: CompositeTransport(mtp: MTPTransport(), adb: adb),
  arrivals: merged(USBWatcher.ticks(), merged(adb.arrivals, vouching.changes)))
let manager = FileProviderDomains()
let domains = DomainController(hub: hub, manager: manager, itemStore: itemStore)
// Devices on the network: connected when the user asks, remembered, and reconnected. A host
// claiming the serial of a device the hub serves is not believed without the user.
let wireless = WirelessADB(
  adb: ADBWireless(), store: wirelessStore,
  known: {
    Dictionary(await hub.devices().map { ($0.id, $0.info.model) }) { first, _ in first }
  }, located: { await domains.location(of: $0) }, vouching: vouching)
Task { await wireless.run() }
Task {
  await manager.conformExisting()
  await domains.run()
}

// The listener holds its delegate weakly; both live for the whole process.
let delegate = AgentListenerDelegate(
  handler: AgentService(hub: hub, domains: domains, wireless: wireless), identity: identity)
let listener = NSXPCListener(machServiceName: identity.machServiceName)
listener.delegate = delegate
listener.resume()
log.info("agent started")

dispatchMain()

/// Ticks whenever either stream does. Ticks that arrive faster than they are read coalesce.
private func merged(_ first: AsyncStream<Void>, _ second: AsyncStream<Void>) -> AsyncStream<Void> {
  AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
    let relays = [first, second].map { stream in
      Task {
        for await _ in stream { continuation.yield() }
      }
    }
    continuation.onTermination = { _ in
      for relay in relays { relay.cancel() }
    }
  }
}
