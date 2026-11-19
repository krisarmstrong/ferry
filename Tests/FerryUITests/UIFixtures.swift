import DeviceKit

/// An attached device as the agent reports it.
func device(
  _ serial: String, model: String, _ state: DeviceState,
  method: ConnectionMethod = .usbFileTransfer
) -> AttachedDevice {
  AttachedDevice(
    info: DeviceInfo(id: DeviceID(serial: serial), manufacturer: "NetAlly", model: model),
    state: state, method: method)
}
