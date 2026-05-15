# NotifBridge

iOS 26.5 `AccessoryNotifications` + `AccessoryTransportExtension` demo with a
Mac acting as a custom Bluetooth LE accessory. Goal: iPhone notification
transport bytes to Mac receiver over BLE.

```
iPhone (iOS 26.5+)                                      Mac (macOS 26+)
-------------------                                      ----------------

 NotifBridge app
 - ASK picker/status
 - forwarding request
        |
        | pairs with advertised BLE service
        v
 AccessoryNotifications
        |
        +--> DataProviderExtension
        |    - add/update/remove callbacks
        |    - serializes title/body/source/id
        |    - session.send(AccessoryMessage)
        |
        +--> TransportSecurityExtension
        |    - generates XWing public/private key
        |    - receives encapsulated key from system
        |    - writes ShareKeyEvent JSON
        |          |
        |          | BLE GATT write:
        |          | D5E1...8C46 keySharing
        |          v
        +--> TransportAppExtension
             - receives encrypted TransportMessage
             - wraps ciphertext + sessionID
             - writes NotificationEnvelope JSON
                   |
                   | BLE GATT write:
                   | D5E1...8C47 notification
                   v
                                                    CBPeripheralManager
                                                    - advertises D5E1...8C44
                                                    - name contains "NotifBdg"
                                                    - reassembles chunks
                                                           |
                                                           v
                                                    HPKEDecryptor
                                                    - derives AES-GCM key
                                                    - decrypts payload
                                                           |
                                                           v
                                                    ReceiverModel / SwiftUI
                                                    - lists notifications
                                                    - posts local Mac banner
```

## Requirements

1. **iPhone Apple Account region = EU**. `AccessoryNotificationCenter` can throw
   `unsupportedPlatform` outside the EU. This is Apple/DMA scoped.
2. **Real iPhone on iOS 26.5+**. Simulator cannot exercise Bluetooth or
   AccessorySetupKit pairing.
3. **No active Apple Watch notification target** while testing, or Watch
   notifications must be disabled. iOS enforces one notification target at a
   time.
4. **Mac with Bluetooth** running macOS 26.0+.
5. **Apple Developer Program membership** with the gated split entitlements:
   - `com.apple.developer.accessory-data-provider`
   - `com.apple.developer.accessory-transport-security`
   - `com.apple.developer.accessory-transport-extension`
6. **Correct extension plist metadata**:
   - all three extensions declare `NSAccessorySetupKitSupports = ["Bluetooth"]`
   - all three declare `NSAccessorySetupBluetoothServices`
   - all three declare `NSAccessorySetupBluetoothNames`
   - `TransportAppExtension` exports a UTI conforming to
     `public.data-access-protocol`

## Layout

```
~/dev/NotifBridge/
├── README.md                              ← you are here
├── docs/
│   └── FINDINGS.md                        ← detailed deep-dive incl. HPKE strategy
├── shared/
│   └── DemoGATT.swift                     ← GATT UUIDs (iOS + Mac)
├── ios/
│   ├── project.yml                        ← xcodegen for iOS app + 3 extensions
│   ├── NotifBridge-iOS.xcodeproj          ← generated
│   ├── AccessoryBLEWriter.swift           ← extension-side CBCentral writer (iOS-only)
│   ├── NotifBridge/                       ← companion SwiftUI app
│   ├── DataProviderExtension/             ← receives notifications, serializes
│   ├── TransportSecurityExtension/        ← XWing key exchange relay
│   └── TransportAppExtension/             ← encrypted payload BLE relay
├── macos/
│   ├── project.yml                        ← xcodegen for Mac app
│   ├── NotifBridge-macOS.xcodeproj        ← generated
│   └── NotifBridge/                       ← SwiftUI + CBPeripheralManager + HPKE decrypt
└── scripts/
    └── test-e2e.sh                        ← automated end-to-end regression
```

## One-Time Build

```bash
# iOS side
cd ~/dev/NotifBridge/ios
xcodegen generate
open NotifBridge-iOS.xcodeproj

# Mac side
cd ~/dev/NotifBridge/macos
xcodegen generate
open NotifBridge-macOS.xcodeproj
```

Team ID `N8YZB43954` is wired into both `project.yml` files. Change
`DEVELOPMENT_TEAM` if using a different account.

## Run

1. **Mac**: build and run `NotifBridge` (mac target). The window should show
   that it is advertising as `NotifBdg`. Approve any Bluetooth permission prompt.
2. **iPhone**: build and run `NotifBridge` on the real iOS 26.5 device.
3. **iPhone**: tap **Pair accessory…**. In the ASK picker, select
   **NotifBridge Mac**. After bonding, the button changes to **Accessory paired**.
4. **iPhone**: tap **Request notification forwarding** and allow the apps you
   want to forward. On later launches, the app refreshes stored forwarding
   status automatically after ASK activation.
5. **iPhone**: trigger a notification (or use the test harness — see below).
6. **Mac**: the decrypted title + body appear in the receiver window. Logs show
   `decrypted NB from MB sess=...` followed by `HPKE-PLAINTEXT ascii=...`.

## Automated End-to-End Test

```bash
./scripts/test-e2e.sh                # random body
./scripts/test-e2e.sh hpke-probe-005 # known body for grepping
```

The script launches the iPhone app with `--send-test-notif --test-notif-body=<body>`,
waits 15s, then greps the Mac receiver log. ✅ when the unique body string is
found in the decrypted plaintext. The harness auto-retries once on a no-decrypt
miss (see Known Issues below).

Always run this regression after touching any Swift source, `Info.plist`,
entitlements, or `project.yml` — a green build does not prove the pipeline still
works.

## Known Issues

**bluetoothd intermittently flags the Transport extension as a non-extension.**
At XPC check-in time, bluetoothd sometimes records the TransportApp extension
as `isExtension false` instead of `isExtension true`. When that happens, the
session is sent to TCC's bundle-list path with `appAuthorizationHasBeenChecked: 0`,
bluetoothd never raises the central state to `On` for that session, and the
extension's `CBCentralManager` stays at `state=4 (poweredOff)` — `attemptConnect`
guards out and no BLE writes happen. Most common on the first launch after a
reinstall. Mitigations:

- Run `scripts/test-e2e.sh`; it auto-retries once on no-decrypt.
- Manually re-launch the iPhone app and trigger another notification; the next
  process is almost always classified correctly.
- Reinstalls reset TCC + per-app forwarding caches and make the misclassification
  more likely on the first attempt.

Pre-warming `CBCentralManager` eagerly in `TransportEventHandler.init` does NOT
help — it shifts the failure to `state=2 (unsupported)` because DeviceAccess
hasn't granted Bluetooth yet at that point.

## What Success Looks Like

Useful iPhone log lines:

```text
deviceaccessd: Issuing sandbox extension mach: Bluetooth
TransportSecurityExtension: direct BLE wrote ShareKeyEvent (...B)
TransportAppExtension: messageReceived ...B
TransportAppExtension: direct BLE wrote ...B
DataProviderExtension: addNotification ...
```

Mac receiver log lines:

```text
keySharing reassembled NB → ShareKeyEvent
keys installed: id=… cipher=XWing v=Version1 …
notification reassembled NB → NotificationEnvelope
decrypted NB from MB sess=…
HPKE-PLAINTEXT ascii=<title><body><source>…
```

## Troubleshooting

| Outcome | Meaning |
|---|---|
| Pair picker does not show Mac | `NSAccessorySetupBluetoothServices` UUID mismatch, Mac not advertising, or `NotifBdg` name filter mismatch. |
| Pair picker errors with `ASErrorDomain 700` | User cancelled. Retry pairing. |
| `requestForwarding` throws `unsupportedPlatform` | Apple Account / platform is outside Apple's supported region. |
| Forwarding status shows `—` briefly on launch | ASK has not emitted `.activated` yet. The app now refreshes status automatically once the paired accessory appears. |
| Forwarding is allowed but extensions never launch | Check `deviceaccessd` for entitlement, provisioning, or plist errors before looking at app logs. |
| Sandbox deny for `com.apple.server.bluetooth.le.att.xpc` | CoreBluetooth was created too early or outside the DeviceAccess-granted extension context. Keep the writer lazy inside Security/Transport handlers. |
| Mac receives encrypted bytes but cannot decrypt | HPKE ciphersuite, key material, or `info` context mismatch. The demo currently uses `.xWing`. |
| Decrypted but garbled body | Wire format mismatch between the iOS encoder and Mac receiver parser. |

## Extension BLE Notes

The active path is direct CoreBluetooth from the Security and Transport
extensions. The host app does not broker extension data.

Important details:

- `TransportEventHandler` sets `session.transport = .bluetooth`.
- Security and Transport handlers store `AccessoryBLEWriter` as a `lazy var`.
  This delays `CBCentralManager` creation until the system has invoked the
  extension for a paired accessory.
- `AccessoryBLEWriter` creates `CBCentralManager` with
  `CBCentralManagerOptionDeviceAccessForMedia: true`.
- The writer retrieves the bonded peripheral from `ASAccessorySession` and
  writes framed chunks (`--START--`, payload chunks, `--END--`) to the target
  characteristic.
- App Group files, App Group UserDefaults, keychain IPC, and loopback networking
  were denied from the extension sandbox. They remain documented in
  `docs/FINDINGS.md` as negative evidence.

## HPKE Decryption

Ciphersuite: `XWingMLKEM768X25519_SHA256_AES_GCM_256`. Apple does not document
the `info` value used for `AccessoryTransportSession` payload encryption. Found
empirically:

```swift
let protocolInfo  = "\(cipherStr)-\(version)-\(identifier)"          // "XWing-Version1-<accessory-uuid>"
let exportContext = "\(protocolInfo)-HostToAccessory-\(sessionID)"

let recipient = try HPKE.Recipient(
    privateKey: privateKey, ciphersuite: .XWingMLKEM768X25519_SHA256_AES_GCM_256,
    info: Data(protocolInfo.utf8), encapsulatedKey: encapsulatedKey
)
let secret    = try recipient.exportSecret(context: Data(exportContext.utf8), outputByteCount: 32)
let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: ciphertext),
                                 using: SymmetricKey(data: secret))
```

No AAD. Ciphertext is the AES-GCM `SealedBox.combined` form (nonce ‖ ciphertext ‖
tag). Implemented in `macos/NotifBridge/HPKEDecryptor.swift`. See
`docs/FINDINGS.md` for the full discovery context.

## Sanity Check Builds

```bash
cd ~/dev/NotifBridge/ios && xcodebuild -project NotifBridge-iOS.xcodeproj \
  -scheme NotifBridge -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build

cd ~/dev/NotifBridge/macos && xcodebuild -project NotifBridge-macOS.xcodeproj \
  -scheme NotifBridge CODE_SIGNING_ALLOWED=NO build
```

Both should print `** BUILD SUCCEEDED **`.

## Useful Logs

```bash
# Mac receiver
log stream --predicate 'subsystem CONTAINS "NotifBridge"' --info

# iPhone via Console.app or idevicesyslog
log stream --predicate 'subsystem CONTAINS "NotifBridge" OR
                        subsystem == "com.apple.deviceaccessd" OR
                        subsystem == "com.apple.CoreBluetooth"' --info
```

The first sign of provisioning, plist, or entitlement trouble usually lands in
`com.apple.deviceaccessd` before either of our subsystems logs anything.

## Cleanup

To repair if pairing gets stuck:

- iPhone: Settings → Privacy & Security → Accessories → remove
  **NotifBridge Mac**.
- Mac: relaunch `NotifBridge` for a fresh advertisement.
