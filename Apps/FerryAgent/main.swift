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
do {
  itemStore = try DomainController.defaultItemStore()
} catch {
  log.fault("no item store: \(error, privacy: .public)")
  exit(EXIT_FAILURE)
}

FileTransfer.sweep()

let hub = DeviceHub(transport: MTPTransport(), arrivals: USBWatcher.ticks())
let manager = FileProviderDomains()
let domains = DomainController(hub: hub, manager: manager, itemStore: itemStore)
Task {
  await manager.conformExisting()
  await domains.run()
}

// The listener holds its delegate weakly; both live for the whole process.
let delegate = AgentListenerDelegate(
  handler: AgentService(hub: hub, domains: domains), identity: identity)
let listener = NSXPCListener(machServiceName: identity.machServiceName)
listener.delegate = delegate
listener.resume()
log.info("agent started")

dispatchMain()
