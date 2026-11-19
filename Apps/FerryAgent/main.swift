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
let toolStore: URL
do {
  itemStore = try DomainController.defaultItemStore()
  wirelessStore = try WirelessADB.defaultStore()
  toolStore = try ToolJournal.defaultStore()
} catch {
  log.fault("no item store: \(error, privacy: .public)")
  exit(EXIT_FAILURE)
}

FileTransfer.sweep()

// MTP and the user's adb server together: each device is served by the best method it offers.
// What the network may serve, as WirelessADB decides; ADBTransport asks it on every scan. It
// serves no network route until WirelessADB below has loaded its store and the domain controller
// has published its Finder locations, so a scan the hub makes first cannot serve a connection the
// adb server kept from before this agent started.
let vouching = WirelessVouching()
// Files the tools left on a device (it went away, or the agent stopped) are removed the next
// time a session for it opens.
let toolJournal = ToolJournal(store: toolStore)
let adb = ADBTransport(
  serving: { vouching.serves($0, as: $1) },
  opened: { id, route, tools in Task { await toolJournal.sweep(id, route: route, using: tools) }
  })
let usbWatch = USBWatchState()
let hub = DeviceHub(
  transport: CompositeTransport(mtp: MTPTransport(), adb: adb),
  arrivals: merged(USBWatcher.ticks(state: usbWatch), merged(adb.arrivals, vouching.changes)))
let manager = FileProviderDomains()
let domains = DomainController(hub: hub, manager: manager, itemStore: itemStore)
// Devices on the network: connected when the user asks, remembered, and reconnected. A host
// claiming the serial of a device the hub serves is not believed without the user.
let wireless = WirelessADB(
  adb: ADBWireless(), store: wirelessStore,
  known: { await hub.shownNames() }, located: { await domains.location(of: $0) }, vouching: vouching
)
Task { await wireless.run() }
Task {
  // Before adoption, so the locations reach the serving check the moment they are known.
  await domains.publishLocations(to: vouching)
  await manager.conformExisting()
  await domains.run()
}

// APK install, screenshots and screen recordings, for devices the hub serves over ADB, by the
// route their session uses.
let tools = ADBTools(
  device: adb.deviceTools,
  target: { id in
    ADBTools.target(for: id, devices: await hub.devices(), session: await adb.sessionRoute(for: id))
  }, journal: toolJournal)

// Changes made on a device reach Finder by themselves: the folders clients listed are watched
// where the device can, and listed again every 30 s, except during transfers or while the Mac
// sleeps.
let transfers = TransferBoard()
let changes = ChangeWatch(domains: domains, transfers: transfers, sleeps: SystemSleep.states())
Task { await changes.run() }

// The listener holds its delegate weakly; both live for the whole process.
let delegate = AgentListenerDelegate(
  handler: AgentService(
    hub: hub, domains: domains, wireless: wireless, tools: tools, usbWatch: usbWatch,
    transfers: transfers, changes: changes),
  identity: identity)
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
