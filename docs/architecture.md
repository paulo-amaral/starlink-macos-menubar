# Architecture

StarPulse is one Swift package with two targets and no third-party dependencies.

| Target | Role |
|---|---|
| `StarPulseCore` | Protocol, decoding, models and logic. No UI. Covered by `swift test`. |
| `StarPulse` | SwiftUI app: menu bar extra, windows, stores, SceneKit dome. |
| `StarPulseCoreTests` | Swift Testing suites with fixtures; optional live read-only tests. |

## Data sources

| Source | Transport | Used for |
|---|---|---|
| Dish `192.168.100.1:9201` | gRPC-web over HTTP | status, history ring buffer, obstruction map, config |
| Router `<default gateway>:9001` | gRPC-web over HTTP | Wi-Fi clients, mesh nodes, Wi-Fi config (read) |
| `starlink.com` (signed in) | HTTPS + session cookie | account, telemetry ids, device pause, DNS |
| `celestrak.org` | HTTPS | Starlink orbital elements (supplemental set, GP group fallback) |
| `speed.cloudflare.com` | HTTPS | speed test; its `cf-meta-ip` header gives the public address |
| `stat.ripe.net` | HTTPS | SpaceX's announced prefixes (AS14593), to say whether a speed test ran over Starlink; only the AS is sent |

The router's `get_ping` request is never sent: on the Starlink router it restarts the device.

## Protocol layer (`StarPulseCore`)

- `GrpcWeb.swift`: unary gRPC-web framing (1 flag byte, 4-byte big-endian length; flag `0x80`
  marks trailers).
- `ProtoWire.swift`: a minimal protobuf reader and writer. Field numbers follow Dishylink's
  `dish.protoset` and `router.protoset`.
- `DishDecoder.swift`, `RouterClient.swift`: turn responses into `DishStatus`, history samples,
  `WifiClient`, `RouterStatus`.
- `StarlinkCloud.swift`, `CloudSession.swift`: account requests and the write path. Writes are
  serialized (one at a time).
- `DevicePause.swift`, `DnsProfiles.swift`: build write requests. A pause request copies every other
  client's entry byte for byte from a fresh router read, changes only the target's schedule and is
  verified before sending.

## Logic

- `ThroughputTracker`: per-device rates from byte counters polled four times a second.
- `LatencyHistory`, `TelemetryStats`: chart windows (15 min, 1 h, 6 h) and statistics.
- `Rules.swift`: rule kinds (schedule, data limit, timer, DNS filter), `RuleEngine` windows,
  `UsageLedger` per-day bytes (40 days at most), `RulePlanner` pause and resume decisions.
- `SGP4.swift`: near-earth SGP4 port, checked against the reference Python implementation to
  1e-10 km in `SGP4Tests`. `Sky.swift` converts TEME to look angles and picks the likely serving
  satellite (highest in a clear part of the sky, re-picked every 15 s slot).

## App layer (`StarPulse`)

- `TelemetryStore` polls the dish and router and feeds every view. `AccountStore` holds the
  Starlink session. `RulesController` applies rules.
- `Theme.swift` and `DesignSystem.swift` hold the type scale (D-DIN, IBM Plex Mono), colours and
  shared controls. Use them for new screens.
- `Anonymizer.swift` (debug builds only) replaces personal data for screenshots.

## What is stored

| Item | Where |
|---|---|
| Starlink session cookie | Keychain |
| Preferences | `UserDefaults` (`app.starpulse.mac`) |
| Orbital elements cache (one file, overwritten) | `~/Library/Caches` |
| Obstruction snapshots (48 at most) | `~/Library/Application Support/app.starpulse.mac/` |
| Rules and per-day usage (`rules.json`) | `~/Library/Application Support/app.starpulse.mac/` |

## Packaging

`scripts/bundle.sh [debug|release]` builds the executable, creates `build/StarPulse.app`, copies
`Info.plist`, the fonts, `oui.json` and the icon into `Contents/Resources`, and signs the app.
Resources are looked up through `Bundle.main` first, because SwiftPM's generated `Bundle.module`
only searches next to the `.app` and inside the build folder of the Mac that compiled it.

## Signing

Without an Apple Developer account the app is signed ad hoc. Each ad hoc build has a new identity,
so macOS asks again for Keychain access after every rebuild. To avoid that, create a self-signed
code-signing certificate named `StarPulse Local Signing` once (Keychain Access → Certificate
Assistant → Create a Certificate, type "Code Signing"). `bundle.sh` uses it when present. It is
valid only on your Mac; it does not replace notarization.

## Tests

```bash
swift test
STARPULSE_LIVE_NET=<router address> swift test     # read-only checks against your router
STARPULSE_LIVE_DIR=<folder with captures> swift test
STARPULSE_TLE_FILE=<TLE file> swift test
```
