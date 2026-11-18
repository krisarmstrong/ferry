import FerryAgentCore
import FerryIPC
import Foundation
import MTPTransport
import os

// The agent: the only process that touches USB. It owns the device sessions, keeps one
// FileProvider domain per storage, and serves the app and the extension on its Mach service.

private let log = Logger(subsystem: "io.github.krisarmstrong.ferry", category: "Agent")

let itemStore: URL
do {
  itemStore = try DomainController.defaultItemStore()
} catch {
  log.fault("no item store: \(error, privacy: .public)")
  exit(EXIT_FAILURE)
}

let hub = DeviceHub(transport: MTPTransport(), arrivals: USBWatcher.ticks())
let domains = DomainController(hub: hub, manager: FileProviderDomains(), itemStore: itemStore)
Task { await domains.run() }

// The listener holds its delegate weakly; both live for the whole process.
let delegate = AgentListenerDelegate(handler: AgentService(hub: hub, domains: domains))
let listener = NSXPCListener(machServiceName: "X6JWYP43HG.io.github.krisarmstrong.ferry.agent")
listener.delegate = delegate
listener.resume()
log.info("agent started")

dispatchMain()
