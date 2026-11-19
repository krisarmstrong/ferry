# Ferry — native ADB engine (design)

Status: draft for owner approval · 2026-11-19

Owner approved the idea (Plan 2b, "Future-release rows": *Native ADB engine*, 2026-11-18). This
document decides how to build it. It contains no product code.

## Intent

Ferry talks ADB to Android devices itself, over USB and over the network, so a user who has
never installed Google's platform tools gets everything Ferry's ADB path gives today: faster
file access than MTP, change pickup with `inotifyd`, and the tools (APK install, screenshots,
recordings, logcat, shell, port forwarding, Wi-Fi).

Today Ferry speaks the adb server's host protocol on `127.0.0.1:5037` and needs an installed
`adb` to start that server and to run `pair` / `connect` / `disconnect`
(spec "ADB", amended 2026-11-18; `Sources/ADBTransport/ADBHost.swift`,
`ADBLocator.swift`, `ADBWireless.swift`). With no `adb`, ADB is unavailable and the menu shows
the Homebrew install line.

## Why

- The install step is the biggest gap between "plug in" and "use the tools". Ferry's users are
  field engineers on a work Mac; many cannot or will not install a developer SDK.
- The `adb` binary's licence does not allow bundling it (spec, ADB engine decision), so the
  only way to remove the step is to speak the protocol.
- The protocol is documented and stable at the layers Ferry needs, and Ferry already
  implements everything *above* the transport (sync, `shell,v2`, legacy shell, `exec:`,
  `inotifyd`, logcat, forwards). The engine replaces one layer, not the ADB stack.

**This is a deliberate non-market build.** Ferry is a personal MIT tool; nothing here is sold.
The reason is user friction for the owner and the people he hands Ferry to. Time budget and
kill criteria are in "Phases"; no market rationale will be back-filled.

## Goals (native engine v1)

1. With no `adb` installed and no adb server running, every ADB feature Ferry ships today
   works over **USB** and over **plain TCP** (`tcpip` / Connect by Address):
   - sync: `STAT`, `LST2`, `STA2`, `LIST`, `LIS2` when advertised, `SEND`, `RECV`, `QUIT`;
   - `shell,v2` with exit status, and the legacy `shell:` fallback with the status echo;
   - `exec:` (screencap, logcat, the `inotifyd` watch);
   - `tcpip:<port>`;
   - port forwarding (Mac port → device port);
   - the existing tools that are built from these (APK install, screen recording to a device
     file then pull, device info, wake).
2. **Android 11+ wireless debugging**: pair with the six-digit code, discover the pairing and
   connect services over mDNS, and connect over TLS (`STLS`). Gated on an Android 11+ test
   device (open question O4).
3. **Authorisation with Ferry's own key**: the device's "Allow USB debugging?" prompt names
   Ferry, and an allowed Mac stays allowed across Ferry restarts and updates.
4. **Coexistence**: a running adb server (Android Studio, a terminal `adb`) keeps working, and
   Ferry keeps serving the device through it, without fighting for the USB interface.
5. Item identity, Finder locations, method preference (USB ADB > MTP > network ADB) and
   `WirelessVouching` behave exactly as today. The extension and the IPC contract for files are
   unchanged. The UI changes only where this design says so: the "Install adb" prompts go, and
   the key fingerprint (Decision 4) and Let adb Use This Device (Decision 6) are added.

## Non-goals (v1)

- **`reverse` forwarding.** Ferry has no caller (only `forward`, `ADBForwards.swift`) and no UI.
  Supporting it means accepting device-initiated `OPEN`s, which is attack surface. Deferred;
  when added, follow adb's host rule: accept a device `OPEN` only for an address Ferry itself
  configured as a reverse target, close everything else (`adb.cpp` `handle_packet`, `A_OPEN`,
  `IsReverseConfigured`).
- **Delayed ACK** (`delayed_ack` feature). No target device has it (Android 8.1 adbd predates it,
  see Decision 3), and adb's own host enables it only with `ADB_BURST_MODE=1`
  (`transport.cpp` `burst_mode_enabled`). The stream layer keeps a send-window abstraction so
  it can be added later.
- **`sendrecv_v2`** (`SND2`/`RCV2`, compression, dry run). Ferry uses v1 `SEND`/`RECV` today; the
  8.1 units do not advertise v2 (`oreo-mr1-release` `transport.cpp` feature list: `shell_v2`,
  `cmd`, `stat_v2`, `libusb`, `push_sync` only).
- QR-code pairing (`studio-…` instances, `docs/dev/adb_wifi.md` "mDNS Service Instance names").
- Live screen-recording streaming, `abb`/`abb_exec`, `jdwp`, `track-app`, `framebuffer:`,
  root/remount, sideload, bootloader/recovery states.
- Emulators (TCP 5555 to localhost works as Connect by Address; no emulator console).
- Being an adb server for other tools. Ferry never listens on 5037.

## Anti-goals (failure even if it "works")

- Ferry starting, killing or detaching the user's adb server, or taking a device away from it
  without the user asking.
- Signing anything other than a 20-byte AUTH token with the ADB key, or using that key for
  anything but ADB.
- A device frame that can make the agent allocate unbounded memory, crash, or hang a Finder
  operation.
- Writing to `~/.android/` (Ferry must never modify the user's adb state).
- Any network scan. Ferry only connects to addresses the user typed, a USB-attached device
  reported for itself, or mDNS advertised for the ADB service types.

## Constraints

- Everything in the main spec's Constraints still holds: Swift 6 strict concurrency, actors and
  async/await, no locks or GCD callbacks in new code where an actor will do, Swift Testing,
  `os.Logger`, String Catalog, macOS 26, Apple silicon.
- **Android 8.1 is the floor and the main target.** All three NetAlly units run adbd from
  `oreo-mr1`. Every protocol choice is checked against `platform/system/core/+/oreo-mr1-release/adb`
  first and against current `packages/modules/adb` main second.
- **The agent is unsandboxed and stays that way.** `com.apple.security.device.usb` is a sandbox
  entitlement ("allow your sandboxed app to interact with USB devices", Apple
  `com.apple.security.device.usb`); the Hardened Runtime's resource-access list has no USB
  entry (Apple "Hardened Runtime"). The FileProvider and Finder Sync extensions never touch the
  engine; no new IPC roles.
- **Local Network privacy applies to the agent.** macOS 15+ exempts launchd daemons, root and
  Terminal-launched tools, and states "the exception for launchd daemons doesn't apply to
  launchd agents" (TN3179, macOS section). Today the agent only touches loopback and the adb
  server makes the LAN connections; natively, the agent's first TCP connect to a device or
  Bonjour browse raises the system's Local Network alert, attributed to Ferry (agent registered
  with `SMAppService`, TN3179 "responsible code"). The agent's Info.plist needs
  `NSLocalNetworkUsageDescription` and `NSBonjourServices`
  (`_adb-tls-pairing._tcp`, `_adb-tls-connect._tcp`). See O3.
- **Licensing.** Our code is MIT. Any vendored crypto (Decision 5) must have an MIT-compatible
  licence, shipped with its notice, built from pinned source in CI like libmtp/libusb.
- **One method per device at a time** (spec "One device, one Finder location"). The engine
  adds routes; it does not change the preference order or the rule that a network route never
  takes over a USB-attached unit's location.

## Decisions

### 1. Scope of v1

In v1, natively, over USB and TCP: everything in Goal 1. Over TLS: Goal 2, in its own phase (P4).

Deferred, with the reason: `reverse` (no caller, attack surface), delayed ACK and `sendrecv_v2`
(no target device supports them; Ferry already has an easy upgrade point), QR pairing, the
services listed under Non-goals. Screen recording keeps today's design: record to a device file,
then pull with `RECV` (`ADBTools+Recording.swift`). It needs nothing new from the engine.

Host-protocol requests Ferry sends today map to native equivalents as follows. None of them goes
to a device as is: they are adb-server functions, so the engine provides each itself.

| Today (host protocol) | Native |
|---|---|
| `host:track-devices-l`, `host:devices-l` | the engine's own device table, fed by `USBWatcher` and its TCP connections |
| `host-serial:<s>:features` | the device's `CNXN` banner `features=` ∩ the features Ferry implements |
| `host:transport-id:<n>` | the engine's connection ID (Decision 7) |
| `host:transport:<s>` + service | `OPEN(local-id, 0, "<service>")` on that connection |
| `…:forward:norebind:tcp:L;tcp:R`, `killforward`, `list-forward` | a loopback `NWListener` on `L` per forward; each accepted socket `OPEN`s `tcp:R` |
| `host:mdns:services` | `NWBrowser` for the two TLS service types |
| `adb connect` / `disconnect` / `pair` | the engine (TCP + handshake, close, pairing client) |
| `adb start-server` | removed (Decision 10) |

`tcp:<port>`, `tcpip:<port>`, `sync:`, `shell:`, `shell,v2,…`, `exec:` are device services and
keep their names (`docs/dev/services.md`, "LOCAL SERVICES").

### 2. USB transport: IOUSBHost, conditional on the P0 spike

**Decision: IOUSBHost (`IOUSBHostInterface` + `IOUSBHostPipe`), not libusb.** Fallback, if P0
fails: libusb, through its own context in the agent.

Reasons:
- IOUSBHost's bulk I/O is asynchronous with completion handlers and has an `async` Swift form
  (Apple, `IOUSBHostPipe.enqueueIORequest(with:completionTimeout:completionHandler:)`). That
  maps straight onto actors and continuations. libusb needs an event-pumping thread and C
  callbacks bridged into Swift 6 concurrency.
- libusb is in Ferry only as libmtp's dependency (LGPL, bundled dylib). Using it directly would
  tie ADB to a library Ferry would otherwise drop if MTP changed.
- Ferry already reads the IOKit registry (`MTPTransport/USBRegistry.swift`) and gets IOKit
  matching notifications on `kIOUSBHostInterfaceClassName` (`FerryAgentCore/USBWatcher.swift`).
  IOUSBHost uses the same services.

**What P0 must prove** (the spike gates this whole decision): one process (FerryAgent) holds a
device's MTP interface through libmtp/libusb **and** its ADB interface through
`IOUSBHostInterface` at the same time. The 2026-11-18 spike showed two *processes* doing this
(FerryAgent on MTP ff/ff/00, the adb server on ADB ff/42/01; `docs/spikes/2026-11-adb.md`). It
did not show one process holding both. If IOUSBHost cannot open the interface beside libusb's
device handle, fall back to libusb for ADB.

Details:
- **Matching.** An interface is an ADB interface when it is class `0xFF`, subclass `0x42`,
  protocol `0x01` (`adb.h` `ADB_CLASS`, `ADB_SUBCLASS`, `ADB_PROTOCOL`), with exactly one bulk IN
  and one bulk OUT endpoint, and no kernel driver attached. Apple devices (vendor `0x05AC`) are
  never candidates (`USBCandidates.appleVendorID`, unchanged). The registry reading moves out of
  `MTPTransport` into a small IOKit-only module (working name `USBRegistry`) used by
  `MTPTransport`, `ADBNative` and `USBWatcher`, so `ADBNative` does not depend on MTP. A
  device in "charging + debugging" mode (`0x18D1_4EE7` today in `chargeOnlyAndroidDevices`,
  listed as *not sharing*) becomes a served ADB device.
- **Claiming.** Open the `IOUSBHostInterface` without `deviceCapture` or `deviceSeize`.
  Capture "terminate[s] all clients and drivers" and needs `com.apple.vm.device-access` or root
  (Apple, `IOUSBHostObjectInitOptions.deviceCapture`). An interface held by another process
  fails with exclusive-access (adb's own macOS backend maps `kIOReturnExclusiveAccess` to
  "another process has device opened for exclusive access", `client/usb_osx.cpp`). Ferry reports
  that as "in use by another program" and goes to Decision 6. After opening, clear stalls on
  both bulk pipes, as adb does (`usb_osx.cpp` `ClearPipeStallBothEnds`; `client/usb_libusb_device.cpp`
  `ClaimInterface` with `libusb_clear_halt`).
- **Framing on USB.** Write the 24-byte header as one bulk OUT transfer and the payload, if any,
  as a second. Read 24 bytes, then exactly `data_length` bytes (`client/usb_libusb_device.cpp`
  `Write`/`Read`).
- **Zero-length packets.** After a payload whose length is a non-zero multiple of the OUT
  endpoint's `wMaxPacketSize`, send a ZLP (`usb_libusb_device.cpp` `Write`: `zlp_mask_ =
  wMaxPacketSize - 1`; `usb_osx.cpp` `usb_write`). IOUSBHost does not add one: "use nil to send
  a zero-length packet" (Apple, `enqueueIORequest`). The 24-byte header never needs one.
- **Max packet size.** Read it from the OUT endpoint descriptor's `wMaxPacketSize` (64 full
  speed, 512 high speed, 1024 SuperSpeed), not from the pipe's burst-inclusive figure. adb notes
  `GetPipePropertiesV3` reports "the FULL maxPacketSize which includes burst and mul"
  (`usb_osx.cpp`).
- **Hot-plug.** `USBWatcher` already ticks on interface arrival and device termination. The
  engine scans the registry on each tick and opens new ADB interfaces. A pipe I/O failing with
  "no device" ends the connection at once (pending streams get `.deviceGone`), without waiting
  for the termination notification.
- **Entitlements.** None new for the unsandboxed agent (see Constraints). ptpcamerad and
  Image Capture never touch the ADB interface.

### 3. Wire protocol

Sources: `docs/dev/protocol.md` (the current copy of protocol.txt), `adb.h`, `adb.cpp`,
`transport.cpp` on main; `adb.h`, `transport.cpp`, `transport_usb.cpp` on `oreo-mr1-release`.

- **Header.** Six little-endian `UInt32`s: `command, arg0, arg1, data_length, data_check,
  magic`, with `magic == command ^ 0xFFFFFFFF` (protocol.md "protocol overview";
  `transport.cpp` `check_header`).
- **Commands.** `CNXN 0x4e584e43`, `AUTH 0x48545541`, `OPEN 0x4e45504f`, `OKAY 0x59414b4f`,
  `WRTE 0x45545257`, `CLSE 0x45534c43`, `STLS 0x534C5453` (`adb.h`). `SYNC 0x434e5953` is
  obsolete and never valid on the wire (protocol.md "SYNC"); receiving it, or any unknown
  command, closes the connection (protocol.md: invalid header or unrecognised command "MUST
  result in the closing of the remote connection").
- **CNXN.** Ferry sends `CNXN(0x01000001, 1 MiB, "host::features=shell_v2,cmd,stat_v2,ls_v2")`.
  The list is exactly the features Ferry implements, from main's names (`transport.cpp`
  `kFeatureShell2`, `kFeatureCmd`, `kFeatureStat2`, `kFeatureLs2`). The usable set is this list
  intersected with the device's (`transport.cpp` `CanUseFeature`). `A_VERSION` and
  `MAX_PAYLOAD` on main are `0x01000001` and 1 MiB (`adb.h`). The banner format is
  `<systemtype>:<serialno>:<banner>` (protocol.md "CONNECT"). The host form is
  `host::features=…` (`adb.cpp` `get_connection_string`). The `CNXN` and any `AUTH` Ferry sends
  before the device's `CNXN` are at most 4096 bytes (protocol.md "CONNECT"; `adb.h`
  `MAX_PAYLOAD_V1`). The device's banner is `device::ro.product.name=…;ro.product.model=…;
  ro.product.device=…;features=…` (`adb.cpp` `get_connection_string`, `parse_banner`). The
  model and features come from there; the serial comes from the USB serial string (USB) or
  `getprop ro.serialno` (TCP), as today.
- **Negotiation.** Effective version = min(ours, theirs) and effective maxdata = min(ours,
  theirs) (`transport.cpp` `update_version`). Android 8.1 adbd has `A_VERSION 0x01000000` and
  `MAX_PAYLOAD 256 KiB` (`oreo-mr1-release/adb/adb.h`). So on every NetAlly unit the
  checksummed version and a 256 KiB maxdata apply.
- **Checksum.** `data_check` is a byte sum of the payload, not a CRC: protocol.md calls the field
  `data_crc32`, but the code is `sum += payload[i]` (`adb.cpp` `calculate_apacket_checksum`).
  - **Sending:** Ferry always fills it in. Main's host sums whenever the transport's version is
    below `A_VERSION_SKIP_CHECKSUM` ("compute a checksum for connection/auth packets for
    compatibility reasons", `transport.cpp` `send_packet`), and the transport starts at
    `A_VERSION_MIN`, so `CNXN` and `AUTH` are always summed. 8.1 adbd verifies the sum on every
    packet it receives over USB (`oreo-mr1-release/adb/transport_usb.cpp`, `check_data`). Summing
    always costs one pass over bytes already in cache.
  - **Receiving:** Ferry verifies the sum while the effective version is `0x01000000` and
    ignores it at `0x01000001` and above. Main no longer checks it at all; 8.1 sends a correct
    one (`oreo-mr1-release/adb/transport.cpp` `send_packet` always sets it).
- **Limits on receipt.** Reject (close the connection) when: the magic is wrong; `data_length`
  is above the effective maxdata (before the device's `CNXN`, above our advertised 1 MiB)
  (`transport.cpp` `check_header`); the command is unknown; `OPEN`/`OKAY`/`WRTE` have a zero ID
  where protocol.md forbids one; an `OKAY` payload is neither 0 nor 4 bytes (`adb.cpp` `A_OKAY`);
  an `AUTH` `TOKEN` is not 20 bytes (`adb.h` `TOKEN_SIZE`, `client/auth.cpp` `adb_auth_sign`);
  or the banner is not UTF-8 or is over 4096 bytes. Messages that arrive before `CNXN` (other
  than `AUTH`/`STLS`) are ignored, as protocol.md requires.
- **Streams.** `OPEN(local-id, 0, "service\0")`, `arg1` always 0. The trailing NUL is
  mandatory: 8.1 adbd overwrites the payload's last byte with a NUL before reading the name, so
  without one it would lose the service name's last character
  (`oreo-mr1-release/adb/adb.cpp` `A_OPEN`: `name[data_length - 1] = 0`; it also ignores an
  `OPEN` with non-zero `arg1`). Main strips trailing NULs (`adb.cpp` `A_OPEN`).
  The device answers `OKAY(its-id, our-id)` or `CLSE(0, our-id)`. Local IDs are non-zero,
  increasing, never reused within a connection. A later `OKAY` whose sender ID does not match
  the first is ignored (`adb.cpp` `A_OKAY`); a `WRTE` or `CLSE` for an unknown ID is ignored
  (protocol.md "WRITE", "CLOSE").
- **Backpressure, without delayed ACK.** One `WRTE` outstanding per stream until the peer's
  `OKAY` (protocol.md "WRITE": a second `WRTE` before `READY` makes the recipient close the
  connection). In the other direction, Ferry sends the `OKAY` for a device `WRTE` only once the
  stream's consumer has taken that payload. So each stream holds at most one maxdata payload,
  and a slow reader (a Finder download into a slow disk) slows that one stream, not the
  connection. `WRTE` payloads Ferry sends are at most the effective maxdata.
- **Delayed ACK (later).** Negotiated through the `delayed_ack` feature on both sides. `OPEN`'s
  `arg1` then carries the window and `OKAY` carries a 4-byte acked count; a mismatch makes the
  device close the `OPEN` (`docs/dev/delayed_ack.md`; `adb.cpp` `A_OPEN`;
  `INITIAL_DELAYED_ACK_BYTES` 32 MiB in `adb.h`). v1 never advertises it, so `arg1` is always 0.

### 4. Auth

- **Key.** RSA-2048, exponent 65537, as adb generates it (`crypto/rsa_2048_key.cpp`
  `CreateRSA2048Key`). Generated by Security.framework, stored in the **Keychain** as a
  non-extractable private key labelled for Ferry. It is not stored in `~/.android/adbkey`, which
  is an unencrypted PEM file (`client/auth.cpp` `generate_key`, `PEM_write_PrivateKey` under
  `umask(077)`).
- **Signing.** `AUTH(TOKEN=1)` carries a 20-byte token. adb signs it with
  `RSA_sign(NID_sha1, token, 20, …)` (`client/auth.cpp` `adb_auth_sign`): PKCS#1 v1.5 with the
  SHA-1 DigestInfo over the token *as a precomputed digest*, not over a hash of it.
  Security.framework's `rsaSignatureDigestPKCS1v15SHA1` takes a digest, which is exactly this.
  Ferry answers `AUTH(SIGNATURE=2, sig)`. A failed signature brings a new `TOKEN`
  (protocol.md "AUTH"), and Ferry tries its next key.
- **Public key.** Once its keys are exhausted, Ferry sends `AUTH(RSAPUBLICKEY=3, …)`. The payload
  is base64 of Android's binary key struct (`modulus_size_words`, `n0inv`, 256-byte LE modulus,
  256-byte LE `rr`, exponent; `libcrypto_utils/android_pubkey.cpp`), then a space and a comment,
  **NUL-terminated** ("adbd expects a null-terminated string", `client/auth.cpp`
  `send_auth_publickey`). `n0inv` and `rr = R² mod n` are computed once from the public modulus
  and cached. Comment: `ferry@<Mac's local hostname>`, without the login name adb includes
  (`crypto/rsa_2048_key.cpp` `CalculatePublicKey` appends `login@host`).
- **Reusing the user's adb key: yes, read-only, as a second key for `AUTH` only.** On USB and
  plain TCP, the AUTH loop tries Ferry's Keychain key first and then, if `~/.android/adbkey`
  exists and parses as an RSA-2048 PEM key, that key. It sends Ferry's public key only after
  both fail. Devices the user already allowed for `adb` then connect without a prompt; every
  new allowance goes to Ferry's own key. The file is read when a connection needs it, held in
  memory only for that connection's AUTH exchange, and never written. `ADB_VENDOR_KEYS` is not
  read. **TLS uses Ferry's key only.** Presenting the adbkey's certificate would mean importing
  it into the Keychain to build a `SecIdentity`, which copies the user's adb key into Ferry's
  storage. A device the user paired with `adb pair` is reached through the user's adb server
  while one runs (Decision 6), or is paired again with Ferry. Owner to confirm (O2).
- **User flow.** When a USB device sends `TOKEN` and no key is accepted, the device shows
  "Allow USB debugging?". Ferry lists it as unauthorised, exactly as today (`ADBDevice.State
  .unauthorized` → "Allow USB debugging on the device"), and waits for the device's `CNXN` with
  no timeout while the cable is in. The menu also shows Ferry's key fingerprint so the user can
  match it with the prompt. Which hash Android 8.1 and current Android display is unverified
  (builder checks on a device, then uses that hash). If the user taps Deny, the device sends
  nothing more; the row stays unauthorised until a replug or Check Again, which reconnects.

### 5. TLS and pairing (Android 11+)

Sources: `docs/dev/adb_wifi.md`; `adb.cpp` (`A_STLS`, `handle_new_connection`);
`transport.cpp` `FdConnection::DoTlsHandshake`; `client/auth.cpp` (`adb_tls_set_certificate`);
`tls/tls_connection.cpp`; `tls/adb_ca_list.cpp`; `crypto/x509_generator.cpp`;
`pairing_auth/pairing_auth.cpp`, `pairing_auth/aes_128_gcm.cpp`;
`pairing_connection/pairing_connection.cpp` and its header; `proto/pairing.proto`;
BoringSSL `include/openssl/curve25519.h` (SPAKE2) and `crypto/curve25519/spake25519.cc`.

**Connect over TLS (STLS).**
1. Ferry sends `CNXN`. On a wireless-debugging port the device answers `STLS(A_STLS_VERSION)`
   instead of `AUTH` (`adb.cpp` `handle_new_connection`, `use_tls`). Ferry replies with
   `STLS(0x01000000)` and starts TLS on the same TCP stream (`adb.cpp` `A_STLS`;
   `A_STLS_VERSION 0x01000000`, `adb.h`).
2. TLS 1.3 only (`tls_connection.cpp`: min and max `TLS1_3_VERSION`). Ferry is the client, the
   device the server (`DoTlsHandshake` roles).
3. The device sends a client-CA list with one entry per host key it trusts: `O=AdbKey-0` and
   `CN=` the uppercase hex SHA-256 of that key's DER SubjectPublicKeyInfo
   (`tls/adb_ca_list.cpp` `CreateCAIssuerFromEncodedKey`, `kAdbKeyValueNid = NID_commonName`,
   `SHA256BitsToHexString`; `daemon/auth.cpp` `adbd_tls_client_ca_list`, `i2d_RSA_PUBKEY`;
   the host computes the same in `client/auth.cpp` `hash_key`). Ferry presents its key's
   certificate whether or not it is listed, as adb does when nothing matches
   (`client/auth.cpp` `adb_tls_set_certificate`). Ferry reads the list only to say "not paired
   with this Mac" sooner when its fingerprint is absent.
4. The certificate is self-signed X.509 v3 from the RSA key: subject and issuer
   `C=US, O=Android, CN=Adb`, basic constraints, key usage, subject key ID, 10-year lifetime,
   SHA-256 signature (`crypto/x509_generator.cpp`). Ferry builds it once and keeps it beside the
   key.
5. After the handshake every ADB message runs inside TLS, and `AUTH` is ignored (`adb.cpp`
   `A_AUTH`). TLS 1.3 gives a rejected client no alert; adb treats a close right after the
   handshake as rejection (`DoTlsHandshake`, `EnableClientPostHandshakeCheck`). Ferry maps that
   to "not paired with this Mac" and offers Pair with Code.

**Pairing** (to the `_adb-tls-pairing._tcp` port the device shows with the code):
1. TLS 1.3 from the first byte, client certificate as above. Any server certificate is
   accepted ("Allow any peer certificate", `pairing_connection.cpp` `SetupTlsConnection`).
2. Export 64 bytes of keying material with label `"adb-label\0"`. The label includes its NUL:
   10 bytes, `sizeof(kExportedKeyLabel)`, no context (`tls_connection.cpp`
   `ExportKeyingMaterial`). The password is the code's ASCII digits followed by those 64 bytes
   (`pairing_connection.cpp`).
3. SPAKE2 as BoringSSL implements it (draft-irtf-cfrg-spake2-02 over Ed25519). Ferry is Alice,
   with names `"adb pair client\0"` and `"adb pair server\0"`; both include the NUL,
   `sizeof(kClientName)` (`pairing_auth.cpp`). Each side sends one 32-byte message
   (`SPAKE2_MAX_MSG_SIZE`). BoringSSL's default "password scalar hack" is part of the result and
   must be reproduced (`spake25519.cc`, `disable_password_scalar_hack`).
4. Packet header: `version u8 = 1`, `type u8` (`SPAKE2_MSG = 0`, `PEER_INFO = 1`), `payload
   u32` big-endian, payload at most 16 384 bytes (`pairing_connection.cpp` `ReadHeader`,
   `kMaxPayloadSize = kMaxPeerInfoSize * 2`; `pairing.proto`).
5. Key: HKDF-SHA256 over the SPAKE2 key material, no salt, info
   `"adb pairing_auth aes-128-gcm key"` *without* its NUL (`sizeof(info) - 1`), giving 16 bytes
   for AES-128-GCM. The nonce is 12 zero bytes with a per-direction 64-bit counter copied into
   the first 8, little-endian on both ends (`aes_128_gcm.cpp`).
6. Each side sends one encrypted `PeerInfo` of exactly 8192 bytes: `type u8` and data. Ferry
   sends `ADB_RSA_PUB_KEY = 0` with its public-key string; the device sends
   `ADB_DEVICE_GUID = 1` with its GUID (pairing_connection.h; `client/adb_wifi.cpp`
   `adb_wifi_pair_device`). Ferry then connects to the matching `_adb-tls-connect._tcp`
   instance, as adb does ("When the pairing client finishes … it also attempts to connect",
   adb_wifi.md "Auto-connect").

**Stack decision (one decision with key storage):**
- **TLS: Network.framework.** `NWProtocolTLS` with TLS 1.3 pinned, the local identity, a verify
  block, and the RFC 5705 exporter from the connection's security metadata. The identity is a
  `SecIdentity` built from the Keychain key and its certificate, so the non-extractable key
  works and no C TLS stack enters Ferry. For pairing (TLS from byte one) this is plain
  Network.framework, *if* four things hold that no source here proves: the exporter accepts a
  label that contains a NUL; a `SecIdentity` over a non-extractable RSA key signs the TLS 1.3
  CertificateVerify (RSA-PSS); the verify block can accept any server certificate while
  recording it for the pin; and TLS 1.3 can be pinned as both minimum and maximum. All four are
  part of the P4 entry spike (O-B7). `STLS` (plaintext first, TLS after) needs a mid-stream upgrade, which
  `NWConnection` has no API for. The one evidence it can be done is an `NWProtocolFramer` that
  runs the plaintext exchange, then calls `prependApplicationProtocol` with TLS options and
  passes through (Apple Developer Forums thread 129901). It is not documented by Apple. **P4
  opens with this spike.** Fallback if it fails: BoringSSL `libssl` from the same vendored build
  as SPAKE2, with memory BIOs over Ferry's own TCP connection and an `SSL_PRIVATE_KEY_METHOD`
  that signs through `SecKey` (RSA-PSS SHA-256 for the TLS 1.3 CertificateVerify), so the key
  stays in the Keychain either way.
- **SPAKE2: vendored, pinned BoringSSL, built from source in CI as a static C target (working
  name `CBoringSPAKE`).** CryptoKit has no SPAKE2 and no Ed25519 point arithmetic (only
  `Curve25519.Signing`/`KeyAgreement`). swift-crypto vendors BoringSSL but does not export it
  (`CCryptoBoringSSL` is not a library product in its `Package.swift`). `spake25519.cc`
  depends on BoringSSL internals (`../fipsmodule/bn/internal.h`, `x25519_ge_*` from
  `curve25519.cc`), so the vendoring unit is BoringSSL's libcrypto built whole with prefixed
  symbols, not two loose files. A Swift port is rejected: it means writing Ed25519 group
  arithmetic and matching a non-standard draft bit for bit, which is more correctness risk
  than a pinned upstream build. HKDF and AES-GCM use CryptoKit. The builder confirms BoringSSL's
  current licence text and ships it.
- **Pinning.** AOSP has no device identity to pin: the host accepts any server certificate on
  both the pairing and the connect port (`DoTlsHandshake`, `SetupTlsConnection`), and pairing
  gives the host only the device's GUID. **Ferry adds trust on first use**: the device certificate
  seen in the code-authenticated pairing (the exporter binds the SPAKE2 run to that TLS
  session, so a MITM without the code cannot complete it) is stored with the GUID and the
  serial. A later connect whose certificate differs is refused with "This device's identity
  changed; pair again", and not silently re-paired. Whether the pairing-port certificate equals
  the connect-port certificate on a real device is unverified (O-B1). If it differs, Ferry pins
  the connect-port certificate on the first TLS connect right after pairing. Pins live in the
  agent's Application Support beside `WirelessStore`, as SHA-256 fingerprints only.
- **mDNS.** `NWBrowser` for `_adb-tls-pairing._tcp` and `_adb-tls-connect._tcp` only, started
  when the user opens Pair with Code or when a paired device is remembered. Instance names are
  `adb-<guid>` (adb_wifi.md "mDNS Service Instance names"); a connect instance is used only for
  a GUID Ferry paired. `_adb._tcp` (the legacy `tcpip` service) is not browsed. Android 8.1 does
  not advertise anything, and Connect by Address already covers those units.

### 6. Coexistence with a running adb server

Today Ferry depends on the server and starts it. Natively, Ferry never starts, stops, kills or
detaches it.

- **Detect.** The existing `trackServer()` on `127.0.0.1:5037` tells Ferry whether a server is
  running and what it holds. It is a loopback connection, which today raises no Local Network
  prompt (O-B6).
- **Default: native unless the server already has it.**
  - A USB ADB interface that appears while no server is running: Ferry claims it natively.
  - A USB device the server lists (it claimed the interface first): Ferry serves it **through
    the server**, with today's host-protocol code (`ServerConnector`, Decision 7). Ferry does not
    try to claim it; if a claim fails with exclusive access, Ferry checks the server's list
    before calling the device "in use by another program".
  - Network devices: always native. adbd accepts any number of host connections on its TCP
    port, each a separate transport (`oreo-mr1-release/adb/transport_local.cpp`
    `server_socket_thread`: accept loop, `register_socket_transport` per connection), so a
    server's TCP connection to the same unit does not conflict. A network device the server holds and Ferry
    has no native route to (for example a phone the user paired with `adb pair` before P4
    shipped) is served through the server, subject to `WirelessVouching` as today.
  - Within Ferry, one session per device, chosen by the existing `CompositeTransport`
    preference. Native and server routes of the same kind rank equal, and the route already
    held is kept, so the method does not flap.
- **A new USB device while a server runs.** Ferry does not claim it at once: the server
  normally claims a new device within moments of attach. Ferry waits for the server to list it
  (bounded at 5 s after the interface appears, from `USBWatcher`'s tick), then serves it through
  the server. If the server has not listed it by then, Ferry tries to claim it. Success means
  native. Exclusive-access failure means "in use by another program", rechecked on each scan.
- **The server exits while Ferry serves a device through it.** The server's interfaces are
  released with its process. Requests in flight fail as they do today when the server dies
  (Plan 2b Review Focus 5). The next scan claims the device natively, and the hub swaps the
  session (same method, "USB · ADB"; domain and item identities unchanged, as in a method
  swap). Network devices the server held and Ferry did not are dropped until Ferry reaches them
  itself (remembered addresses) or the server returns.
- **A server that starts while Ferry holds a USB device natively.** Ferry keeps the device. The
  server cannot claim it, so `adb devices` does not list it. The device's menu expansion offers
  **Let adb Use This Device**. It waits for in-flight requests (the hub's session-swap rule),
  releases the interface, and serves the device through the server once the server lists it.
  Ferry does not yield automatically on every server start: a terminal `adb` invocation starts
  the server, and automatic yielding would swap methods under a running copy. Owner to confirm
  (O5). Whether a server that is already running picks up an interface released after it
  started is unverified (P0 question); if it does not, the button's help says to replug.
- **`kill-server`: never. `host:…:detach`: not in v1.** Current adb has `detach`/`attach` host
  services ("Only valid when running with libusb backend", `docs/user/adb.1.md` "USB";
  `adb.cpp` `service == "detach"`). libusb is the default backend on macOS on main
  (`client/transport_usb.cpp` `is_libusb_enabled`: on except Windows). Asking the user's server
  to drop a device would surprise other tools (Android Studio shows it detached) and needs
  version checks against whatever platform-tools the user has. Ferry uses the server route
  instead.

### 7. Architecture

New module **`ADBNative`** beside `ADBTransport`, depending on `DeviceKit`, IOKit/IOUSBHost,
Network, Security, CryptoKit and (P4) `CBoringSPAKE`. `ADBTransport` keeps everything above the
connection.

**The seam: services over byte streams.** Every ADB feature Ferry has already runs over an
`ADBStream`, a byte pipe with `read(exactly:)`, `readSome(upTo:)`, `write(_:)`, `close()` and a
nonisolated `cancel()` (`ADBStream.swift`). `ADBSync`, `ADBShell`, `ADBLogcat`, the
`inotifyd` watch and `ADBDeviceTools` only read and write that pipe after the service is
selected. The engine does not change them.

1. `ADBStream` becomes a protocol, `ADBByteStream`, with the same five members. Today's actor
   becomes `ServerStream` (TCP to 5037). The engine adds `NativeStream`.
2. `ADBHost`'s device-facing API becomes a protocol, **`ADBConnector`**:
   `open(route, service) -> any ADBByteStream`, `features(route)`, `run(route, command, …)`
   (shell, built on `open`), and the forward calls. It also has `devices()` and a device-change
   stream that today come from `track-devices-l`. `ServerConnector` is today's `ADBHost` minus
   `startServer`. `NativeConnector` is the engine. `ADBTransport`, `ADBSession`,
   `ADBDeviceTools` and `WirelessADB` take a connector instead of an `ADBHost`. They are
   otherwise unchanged, as are `DeviceTransport`, `DeviceSession`, the hub and the IPC.
3. A route keeps today's meaning: it names one connection, not just a serial (item 4 gives its
   new shape). On the native side the connection is the engine's connection ID: a 64-bit
   counter, new for every USB claim and every TCP/TLS
   connection, never reused while the agent runs. A route pinned to a connection that has
   ended fails `open` with `.deviceGone`, which is today's `transport_id` guarantee
   (`ADBRoutes.swift`, `ADBTransport+Transports.swift` `noteTransports`). A reconnect to the
   same address, which could be another unit, never inherits a route.
4. **Two connectors at once, one route type.** Decision 6 serves some devices through the
   server and others natively at the same moment, so `ADBRoute` says which side it belongs to:
   `ADBRoute(serial:, via:)` with `via` either `.server(transportID: String?)` (adb's
   `transport_id`) or `.native(connection: UInt64)`. One `RoutingConnector` is what
   `ADBTransport` and the tools hold. It dispatches each call on `route.via` and merges the two
   device tables, tagging each entry with its side. A route never crosses sides. Both IDs are
   small integers, and a server ID reaching the native table (or the reverse) could open
   another unit, so the side is part of the route's identity, its `Hashable` conformance and
   the pinning check in `noteTransports`.
5. `WirelessADBControl` (`WirelessADB.swift`) is already the seam for wireless. A native
   implementation replaces `ADBWireless`: `connect` = TCP + handshake, `pair` = the pairing
   client, `mdnsServices` = `NWBrowser` results, `restartInTCPMode` = `OPEN tcpip:<port>`,
   `disconnect` = close. `trackServer()` stays only to learn when the server comes or goes, for
   Decision 6.

**Inside the engine (Swift 6):**
- `actor ADBConnection`, one per device link. It owns the link (a `USBLink` over two
  `IOUSBHostPipe`s, a `TCPLink` over `NWConnection`, or a `TLSLink`), runs the CNXN/AUTH/STLS
  state machine, and holds the stream table. A single reader task parses frames with the pure
  `ADBFrameParser` and routes them; writes are serialised by the actor.
- `NativeStream` (one per `OPEN`). Its receive side is a one-slot buffer plus the deferred
  `OKAY` (Decision 3). Its send side awaits the peer's `OKAY` through a continuation. It
  conforms to `ADBByteStream`.
- **Cancellation.** Today, cancelling a read closes the socket, which ends that service
  (`ADBStream.receive`). Natively, streams share one link, so `cancel()` on a stream sends
  `CLSE(local, remote)`, fails that stream's pending read and write at once with `.cancelled`,
  and drops later frames for its ID (protocol.md: a closed ID's frames are ignored). The link
  and other streams are untouched. `ADBSync`'s "close the connection after any error" rule
  (`ADBSync.swift` header) still holds per stream. A link-level failure (USB I/O error, TCP
  reset, bad frame) fails every stream on it with `.connectionClosed` and ends the connection
  ID.
- **Operation gate and DeviceTurn.** `OperationGate` and `DeviceTurns.take()` live in
  `ADBSession` and `ADBSync` above the seam (`ADBSession.swift`, `ADBSync.swift`,
  `DeviceKit/DeviceTurn.swift`) and are unchanged. The engine adds no queueing that would make
  a turn wait on another stream: streams progress independently, and one device link carries
  any number of them.
- **Device table.** `NativeConnector` publishes `[ADBDevice]` (serial, state, wireless,
  model, product, connection ID), the shape `ADBWire.devices` produces today, so
  `ADBTransport`'s scan, merge-by-serial and vouching logic stay as they are.

**Tests and fakes stay reusable.** `FakeAndroid` (filesystem, toybox shell, sync handler) speaks
services over a `Peer` stream (`FakeAndroid+Server.swift`). A device-side wire front end
(`FakeADBDevice`) wraps it: it speaks CNXN/AUTH/OPEN/WRTE/OKAY/CLSE on an in-memory link and
hands each `OPEN` to the same service handlers. The existing session, sync, shell, watch and
tools tests then run unchanged against both connectors (parameterised). The in-memory link also
avoids loopback sockets, the source of the `ADBSyncTests` flake (Plan 2b Task 12).

### 8. Security

**Key protection.** The private key never leaves the Keychain: non-extractable,
available after the Mac's first login since boot, this device only (the Keychain's
"after first" accessibility class), no iCloud sync, access limited to the agent.
Data-protection keychain with a team-prefixed access group is preferred. It may need a
provisioning profile for the agent's application identifier; if so, and the owner does not want
one, use the file-based login keychain with an ACL to the agent's designated requirement
(builder checks; O-B2). The certificate and the Android-format public key are not secret and
live in Application Support. `~/.android/adbkey`, when used (Decision 4), is read only for the
AUTH exchange.

**Threat model.**
- *Malicious USB device* (looks like Android, is not):
  - Every frame is bounded (Decision 3 limits) and parsed by one pure function.
  - Device-initiated `OPEN` is refused with `CLSE` (no `reverse` in v1).
  - Per-stream memory is one maxdata payload; streams per connection are capped (64).
  - The banner's model is display text only; identity is the USB serial as today, and the
    method-preference rule still keeps a network route off a USB unit's location.
  - **Inherited from adb, accepted:** a device can send any 20 bytes as a `TOKEN` and get a
    PKCS#1 SHA-1 signature over them. That is a signing oracle. A hostile device could relay a
    real device's token and so authenticate to that real device as this Mac, if that device
    trusts Ferry's key and the attacker controls both. adb has the same exposure
    (`client/auth.cpp` `send_auth_response`). Ferry limits it: the key signs only 20-byte
    tokens, only on an ADB link, and is used for nothing else.
- *MITM on Wi-Fi:*
  - Plain TCP (`tcpip`, Connect by Address; all 8.1 units) has no encryption and no device
    authentication. A network attacker can read and change everything and relay AUTH
    (adb_wifi.md: the legacy path "results in an insecure channel"). This is no change from
    today. `WirelessVouching`'s rules still decide which address may serve which device. The
    Wi-Fi help topic says to use plain TCP only on a trusted network (add the sentence if Plan 2b
    Task 19 has not).
  - TLS devices get pairing protected by the code (SPAKE2 bound to the TLS exporter) plus Ferry's
    certificate pin (Decision 5). That is stronger than adb, which accepts any device
    certificate.
- *Hostile process on the Mac:*
  - It cannot use the key without the Keychain's consent.
  - It can connect to forwarded loopback ports, exactly as with adb's forwards; forwards stay
    on `127.0.0.1` only.
  - It can run its own adb server, which Ferry would then use for USB devices it claimed
    (Decision 6). That is the same trust Ferry gives the server today: loopback with no
    authentication.
  - No new XPC roles or Mach services; the engine lives in the agent.

**Fuzzing and limits.** Swift's libFuzzer integration (`-sanitize=fuzzer`) is not assumed
available in Xcode's toolchain (unverified). So:
- `ADBFrameParser`, `CNXN` banner parsing, `PeerInfo`/pairing-header parsing and the Android
  public-key encoder are pure functions over `Data` with explicit limits.
- Each gets seeded randomised tests in Swift Testing: mutations of golden frames plus random
  frames, a fixed seed in CI and a long-run mode locally. Properties: never crashes, never
  allocates more than the limit, rejects or accepts deterministically.
- If the open-source toolchain on a dev server offers libFuzzer, a harness over the same pure
  functions is added there. It is not a CI gate.

### 9. Testing

- **Golden wire bytes.** Fixed byte strings for:
  - header encode and decode, every command, and the checksum (including a payload whose sum
    wraps);
  - `CNXN` both ways (host banner and an 8.1 device banner);
  - an AUTH round with a fixed test key and token, checked against an RSA PKCS#1 v1.5 SHA-1
    reference;
  - `RSAPUBLICKEY` with its trailing NUL, against an Android-format key from AOSP's
    `android_pubkey` for the same modulus;
  - `OPEN` with a trailing NUL, `OKAY`/`WRTE`/`CLSE` sequences, and ZLP decisions at 511, 512
    and 1024 bytes for 512- and 1024-byte endpoints;
  - the pairing header, HKDF output and the GCM nonce sequence;
  - one SPAKE2 run with fixed randomness, cross-checked against the vendored BoringSSL in a
    test.

  The existing `ADBWireGoldenTests` style is kept.
- **Fake device.** `FakeADBDevice` (Decision 7) with scripted behaviour:
  - 8.1 (version `0x01000000`, 256 KiB, checksums, no `ls_v2`);
  - current (`0x01000001`, 1 MiB);
  - unauthorised then allowed;
  - denied;
  - a wrong checksum, a short `TOKEN`, an oversize frame, a device `OPEN`, a `WRTE` before
    `OKAY`;
  - a wedged stream beside a healthy one;
  - unplug mid-`RECV`;
  - TLS-port behaviour (`STLS` reply) for the state machine. The TLS bytes themselves are
    tested with a loopback TLS server in P4.

  All existing `ADBSession`/`SafeWriter`/sync/shell/watch/tools tests run against the native
  connector over the fake.
- **Fuzz/randomised tests** as in Decision 8, bounded under `timeout` like every Ferry test.
- **Live verification (owner's units):**
  - LinkRunner 10G, LinkRunner 100G, EtherScope nXG on Android 8.1, over USB with no adb
    server running (`adb kill-server` once before the run; from P2 Ferry never starts one): the
    Plan 2b Task 11 list (5 GB copy with SHA match, names from
    Review Focus 3, method swaps, inotify pickup, tools, port forward), and Allow/Deny on a
    fresh key.
  - The same over Connect by Address on 192.0.2.x.
  - With the adb server running: Ferry serves through it, and Let adb Use This Device
    releases a natively held unit.
  - Throughput: native vs the server path on the same 5 GB file (kill criterion below).
  - Android 11+ phone, if available: pair with code, reconnect after a reboot, pin mismatch
    after "Revoke USB debugging authorisations" and re-pair.

### 10. Migration

Pre-1.0, no shims. Once native USB and TCP pass live verification (end of P3), the code that
**finds and runs `adb`** is deleted:
- `ADBLocator`, `ADBCommand`'s `start-server`/`pair`/`connect`/`disconnect` runner, and the
  `trackDevices` path that starts the server;
- `ADBStatus.notInstalled`, the "Install adb for more tools…" row, its Copy button, the setup
  guide's install line, and help topics that mention installing platform tools;
- the README's "Optional … `adb`" requirement.

**Kept: the host-protocol client, as `ServerConnector`, used only while a server the user
started is running.** It is not a compatibility path. It is how Ferry coexists with Android
Studio and terminal `adb` (owner row: "use the server when present"), and it serves a TLS device
the user paired with `adb pair` until P4 lands. Without it, any user who runs adb would lose
Ferry's ADB features whenever the server holds a device. It is existing, tested code. Ferry
never starts that server.

### 11. Phases, effort, time budget, kill criteria

**Time budget: 30 working days of build effort, ending no later than 2027-02-26.** Owner to
confirm (O1). Effort is rough agent-driven build time including tests and reviews, not calendar
time.

| Phase | Ships | Effort | Exit / kill |
|---|---|---|---|
| **P0 Spike** | `docs/spikes/2026-11-native-adb.md` | 2 d | On a LinkRunner with the adb server stopped: open the ADB interface with IOUSBHost beside Ferry's libmtp session, run CNXN → AUTH (adbkey and a fresh key) → `OPEN sync:` → one `STAT`. Record `wMaxPacketSize`, the device banner, and whether a running server picks up a released interface. **Kill:** neither IOUSBHost nor libusb can hold the ADB interface while libmtp holds MTP in the same process, and serving ADB-only (MTP closed) is unacceptable to the owner. Then stop; external adb stays. |
| **P1 Engine core** | `ADBNative` with USB link, wire layer, auth, streams, `FakeADBDevice`, golden and fuzz tests; `ADBByteStream`/`ADBConnector` seam in `ADBTransport` with all existing tests green on both connectors | 8 d | Every existing ADB test passes over the native connector on the fake. |
| **P2 Native USB in the agent** | Device table from `USBWatcher`, connection IDs, `RoutingConnector`, coexistence policy, Let adb Use This Device, native forwards. **Ferry stops starting the adb server here** (device tracking no longer calls `startServer`), so the anti-goal holds from P2. Until P3/P4, `adb pair`/`connect` still run when the user picks Pair with Code or Connect by Address, and those start a server, which then claims USB interfaces Ferry does not already hold. That interim behaviour is accepted and noted in help. Live run on the three units. Shippable: USB ADB with no `adb` installed | 6 d | Task 11 list passes on all three units. **Kill / rethink:** native 5 GB transfer below 70 % of the server path's throughput on the same unit and cable after one profiling pass. |
| **P3 Native TCP** | Connect by Address, Use over Wi-Fi (`tcpip`), remembered addresses; Local Network usage string; removal of the `adb` locator/launcher (Decision 10). Shippable: everything Ferry does today on the NetAlly units, no install | 4 d | EtherScope over 192.0.2.x passes Task 11's Wi-Fi rows. |
| **P4 TLS + pairing** | STLS framer spike first (1 d), then vendored BoringSSL SPAKE2, pairing client, mDNS, pinning | 9 d | **Gate:** an Android 11+ device is available (O4). **Kill:** the STLS framer and the BoringSSL `libssl` fallback both fail to interoperate within 3 days of P4, or no Android 11+ device by the end of P3. Then P4 is shelved; TLS devices are served only through a user-run adb server, and help says so. |
| Reserve | Review rounds, live-run defects | 1 d | |

Each phase ends with a PR that leaves Ferry shippable. After P2 the external path still covers
TCP and pairing until P3/P4.

## Open questions for the owner

- **O1 Time budget.** 30 working days, hard stop 2027-02-26, with the kill criteria above.
  Accept, or set another cap?
- **O2 Reuse `~/.android/adbkey`?** Recommended: yes, read-only, for USB and plain-TCP `AUTH`
  only, tried after Ferry's own key, so units already allowed for adb need no new tap; never
  written. TLS (Android 11+) uses Ferry's key only, so phones paired with `adb pair` pair again
  with Ferry, or are reached through a running adb server. The alternative is a clean break:
  Ferry's key only, and every unit asks "Allow USB debugging?" once.
- **O3 Local Network prompt.** Native Wi-Fi makes macOS ask "Allow Ferry to find devices on
  local networks?" the first time the agent connects to a device on the LAN or browses mDNS.
  Accept, with the prompt raised only when the user first uses a network feature, never at
  launch?
- **O4 Android 11+ test device.** P4 (TLS pairing) cannot be verified on the 8.1 units. Is an
  Android 11+ phone available? Without one, P4 is shelved at the end of P3.
- **O5 adb starts while Ferry holds a device.** Recommended: Ferry keeps the device and offers
  "Let adb Use This Device"; it never yields on its own. The alternative is yielding
  automatically whenever a server appears, at the cost of method swaps whenever any terminal
  `adb` command starts a server.
- **O6 Signing.** If the data-protection keychain needs a provisioning profile for FerryAgent's
  application identifier, may the builder add one (the app group already needs the owner to
  create identifiers in the portal)? Or use the login keychain with an ACL?

## Open technical questions (the builder settles these; none needs the owner)

- **O-B1** Does an Android 11+ device present the same certificate on its pairing port and its
  connect port? This decides which certificate Ferry pins (Decision 5).
- **O-B2** Data-protection keychain from a launch agent: entitlements and profile needed (O6).
- **O-B3** Which fingerprint hash the "Allow USB debugging?" dialog shows on 8.1 and on current
  Android, so Ferry shows the same one.
- **O-B4** Does a running adb server (platform-tools 37.0.1, libusb backend) claim an
  interface Ferry releases after the server started, or only on replug? (P0)
- **O-B5** Does IOUSBHost open the ADB interface while libmtp/libusb holds the same device in
  the same process? (P0, gates Decision 2)
- **O-B6** Does Local Network privacy leave the agent's loopback connections to 5037 and to
  forward listeners unprompted? TN3179 does not say; today's behaviour (no prompt) suggests yes.
- **O-B7** P4 entry spike, Network.framework TLS on macOS 26:
  - the STLS `NWProtocolFramer` upgrade;
  - the RFC 5705 exporter with the 10-byte label `"adb-label\0"`;
  - a `SecIdentity` over a non-extractable Keychain RSA key signing TLS 1.3 RSA-PSS;
  - a verify block that accepts any server certificate and records it;
  - TLS 1.3 as both minimum and maximum.

  Any failure moves TLS to the BoringSSL `libssl` fallback.
- **O-B10** Does adbd accept a host banner that advertises only
  `shell_v2,cmd,stat_v2,ls_v2` and behave as with adb's full list for every service Ferry
  uses? (P0 on 8.1, P4 on Android 11+.)
- **O-B8** Is libFuzzer usable with Xcode 27's Swift toolchain? If yes, add a harness; it is not
  required.
- **O-B9** Does `detach` exist in platform-tools 37.0.1's adb? It is not used in v1; record it
  for later.

## Left to the builder

Module and type names beyond those fixed here (`ADBNative`, `ADBByteStream`, `ADBConnector`,
`NativeConnector`, `ServerConnector`, `FakeADBDevice`, `USBRegistry`, `CBoringSPAKE` are
working names). Also:
- the exact stream cap and per-connection limits;
- how the X.509 certificate is built in Swift (hand DER or `swift-certificates`);
- the big-number code for `n0inv`/`rr`;
- the BoringSSL pin and CI build mechanics (mirror the libmtp/libusb release build);
- the exact menu wording for Let adb Use This Device and the identity-changed error (String
  Catalog);
- help-topic updates;
- how `CompositeTransport` ranks equal native and server routes so the held one wins.

## Sources

Fetched 2026-11-19. AOSP paths are under
`android.googlesource.com/platform/packages/modules/adb/+/refs/heads/main/` unless marked
**8.1**, which are under `android.googlesource.com/platform/system/core/+/refs/heads/oreo-mr1-release/adb/`.

- `docs/dev/protocol.md` (protocol.txt): header, CNXN, STLS, AUTH, OPEN/READY/WRITE/CLOSE, SYNC
  obsolete, 4096-byte pre-CNXN limit.
- `docs/dev/delayed_ack.md`: delayed ACK, `OPEN` `arg1`, `OKAY` payload.
- `docs/dev/services.md`: local services (`shell,v2`, `exec:`, `tcp:`, `sync:`, `reverse:`).
- `docs/dev/sync.md`, `file_sync_protocol.h`: sync IDs and structs (unchanged above the seam).
- `docs/dev/adb_wifi.md`: pairing, STLS socket, mDNS types and instance names, auto-connect.
- `docs/user/adb.1.md`: `attach`/`detach` (libusb backend only), `ADB_LIBUSB`.
- `adb.h`: command constants, `A_VERSION*`, `A_STLS_VERSION*`, `MAX_PAYLOAD*`,
  `INITIAL_DELAYED_ACK_BYTES`, `TOKEN_SIZE`, `ADB_CLASS/SUBCLASS/PROTOCOL`.
- `adb.cpp`: `calculate_apacket_checksum`, `get_connection_string`, `send_connect`,
  `send_tls_request`, `handle_new_connection`, `handle_packet`, host `detach`/`attach`.
- `transport.cpp`: `send_packet` checksum rule, `update_version`, `check_header`, feature names,
  `burst_mode_enabled`, `FdConnection::DoTlsHandshake`.
- `client/auth.cpp`: key file, `adb_auth_sign`, `send_auth_publickey`, `send_auth_response`,
  `adb_tls_set_certificate`.
- `crypto/rsa_2048_key.cpp`, `crypto/x509_generator.cpp`, `tls/adb_ca_list.cpp`,
  `tls/tls_connection.cpp`.
- `pairing_auth/pairing_auth.cpp`, `pairing_auth/aes_128_gcm.cpp`,
  `pairing_connection/pairing_connection.cpp`,
  `pairing_connection/include/adb/pairing/pairing_connection.h`, `proto/pairing.proto`,
  `client/adb_wifi.cpp`.
- `client/usb_osx.cpp`, `client/usb_libusb_device.cpp`, `client/transport_usb.cpp`: claiming,
  ZLPs, max packet size, libusb default.
- `shell_protocol.h`: shell v2 packet IDs (unchanged above the seam).
- `platform/system/core/+/main/libcrypto_utils/android_pubkey.cpp`: Android public-key struct.
- **8.1** `adb.h` (`A_VERSION 0x01000000`, 256 KiB), `transport.cpp` (`send_packet`,
  `check_data`, features), `transport_usb.cpp` (verifies `check_data` on receipt).
- BoringSSL `include/openssl/curve25519.h` (SPAKE2 API; draft-irtf-cfrg-spake2-02) and
  `crypto/curve25519/spake25519.cc` (dependencies, password scalar hack); swift-crypto
  `Package.swift` (CCryptoBoringSSL not a product).
- Apple: TN3179 *Understanding local network privacy* (macOS section);
  `IOUSBHostObjectInitOptions.deviceCapture`; `IOUSBHostPipe.enqueueIORequest(…)`;
  `com.apple.security.device.usb`; *Hardened Runtime*; Developer Forums thread 129901
  (STARTTLS with `NWProtocolFramer`).
- Ferry: spec `2026-11-17-ferry-design.md`; plan `2026-11-18-ferry-adb.md`;
  `docs/spikes/2026-11-adb.md`, `2026-11-ptpcamerad.md`; `Sources/ADBTransport/*`,
  `Sources/FerryAgentCore/{WirelessADB*,WirelessVouching,USBWatcher,CompositeTransport}.swift`,
  `Sources/MTPTransport/{USBCandidates,USBRegistry}.swift`, `Tests/ADBTransportTests/`.

## Owner decisions (2026-11-19)

- O1 Budget: 30 working days in five phases, hard stop 2027-02-26, per-phase kill criteria as written.
- O2 `~/.android/adbkey`: reused read-only as a second key for authorisation; never written. Ferry's own key lives in the Keychain.
- O3 Local Network prompt: accepted; asked on first use of a network feature, never at launch.
- O4 Android 11+ test phone: available; phase P4 (TLS pairing) stays in.
- Controller calls (owner may override): O5 Ferry keeps a device it holds when an adb server starts and offers "Let adb Use This Device"; O6 a provisioning profile may be added for FerryAgent's Keychain access if required, else login keychain bound to the agent's signature; delayed ACK and `reverse` deferred (no target device supports delayed ACK; Ferry has no `reverse` caller).
