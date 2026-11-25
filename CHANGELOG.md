# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.7] - 2026-11-25

### Added
- Router speed test: the speed test can run on the Starlink router itself (This Mac or Router),
  so Wi-Fi and the Mac are not part of the result. Speeds are the average of the router's
  readings; latency, jitter, loss and bufferbloat still come from the dish.
- Settings › Starlink shows the dish's hardware self-test (Passed or Failed), and Settings ›
  Router shows connected devices per Wi-Fi band and by cable. Both are read once when the pane
  opens.

## [0.1.6] - 2026-11-25

### Added
- Dish update notification: when the dish has installed an update and waits to restart, a
  notification and an "Update ready" notice say when (for example "tomorrow around 04:05"), from
  the dish's own schedule, or its update window when it gives no time. Once per update; switch in
  Settings › App › Notifications.
- Install update now: Settings › Starlink › Maintenance offers "Restart now…" while an update
  waits, so the dish finishes it at once instead of in its update window.
- Service notices in the popover: service restricted (no active plan, account disabled, data
  limit reached, location rules) and speed limits, read from the dish.

### Changed
- A pending update no longer shows as a red alert in the popover.

## [0.1.5] - 2026-11-25

### Added
- Packet loss notification: pings lost (10% by default), without a full outage, for over a
  minute. On by default.
- Latency notification: median latency high (150 ms by default) for over a minute. Off by default.
- Settings › App › Notifications, with one switch per notification and a choice of limits:
  loss 5, 10 or 20%; latency 100, 150 or 250 ms.

### Fixed
- docs/architecture.md now credits the `get_ping` finding to Dishylink and lists every request
  StarPulse sends.

## [0.1.4] - 2026-11-25

### Added
- Outage notifications: a macOS notification when Starlink has been down for 30 seconds, and
  another with the outage length when it is back. Turn it off in Settings › App › General.
- Outage alert in the dashboard: a red banner while the dish reports no connection, also counted
  in the alerts bell.
- When the dish does not answer, the popover and dashboard say why: no network, an address clash
  with 192.168.100.x, a VPN in the way, no route to the dish (bypass mode without a static route),
  or a silent dish behind a Starlink router.
- Universal app: runs on Apple silicon and Intel Macs.

### Changed
- Dish alerts in plain words ("Heating to melt snow" instead of `isHeating`).
- During an outage the menu bar shows "Outage", and "Offline" when the dish cannot be reached,
  in place of numbers from before the drop.

## [0.1.3] - 2026-11-24

### Added
- Menu bar readout for the content filter ("Filter Off", "Filter Malware", "Filter Adult + malware"),
  turned on in Settings › App › Menu bar.
- Content filtering, as in the Starlink app (No filtering, Malware, Malware and adult content), from
  the menu bar popover and Settings › Router. Pick an option and Save; it is sent through your Starlink
  account after the router check, then read back from the router.

## [0.1.2] - 2026-11-24

### Added
- Throughput statistics: peak and average download and upload for today, 7 days, this month or
  30 days, kept for 62 days on this Mac (#104).
- Alignment: a 3D view of the dish inside a glowing outline of where it should point, with turn and
  tilt steps when it needs adjusting.
- Speed test: says whether it ran over Starlink (Dishylink issue #71).
- Router settings: WAN IPv4 (marked when behind Starlink's CGNAT) and IPv6 addresses (#105).
- Settings: fixed throughput unit, Mbps or Kbps (#4), and a fixed throughput chart scale (#50).
- Settings: Open at login (#57).
- Satellites: a marker where the beam leaves the dome (#66).
- Devices: sort by activity, data usage or name, with usage shown per device (#60).

### Fixed
- Chart lines no longer change shape as new data arrives: points are thinned by the dish's own sample
  counter instead of by position (#67).

## [0.1.1] - 2026-11-24

### Added
- Settings: Reboot Starlink and Reset obstruction map, with confirmation. Sent over the LAN, or
  through the Starlink account when the dish refuses local writes.

### Security
- Dish maintenance through the account is sent only when the dish on the LAN is one of the
  account's dishes, matching the router check.

### Changed
- The popover's Obstructions page uses the dashboard's 3D dome, time-lapse and figures.
- README: logo, animated demo of the menu bar and dashboard.

### Removed
- The flat obstruction map view, replaced by the 3D dome.

## [0.1.0] - 2026-11-24

First public release.

### Added
- Menu bar readouts (status, latency, ping success, throughput, power) and a popover in the style of
  the Starlink app.
- Dashboard: live tiles, throughput, latency (15 min, 1 h, 6 h) and power charts, 3D obstruction dome
  with an hourly time-lapse, events and outages.
- Statistics, latency detail with Starlink and router comparison and distribution.
- Network: devices with live per-device throughput, details and history; nodes; rules.
- Rules: schedules, data limits, timers and network DNS filters that pause and resume devices.
- Device pause and resume through the Starlink account, with byte-for-byte preservation of the
  router's client list and pre-send verification.
- Live satellite view: SGP4 propagation of the Starlink constellation over the obstruction map, with
  the likely serving satellite.
- Speed test against Cloudflare with a speedometer gauge.
- Alignment check, read-only dish and router settings, Starlink account sign-in.
- Guides to set up DNSBunker and dnsforge on individual devices.
- Bufferbloat grade in the speed test (latency under load against idle, Waveform's scale).

### Security
- Writes to the router are refused unless the router on the LAN has the same device ID as the
  router on the Starlink account.
- Rule pauses wait up to 2 minutes for the router to show them before a resumed device counts as
  a manual override; a pause that never shows is sent again.
- Decoders no longer trap on out-of-range numbers from the LAN; cookies are kept only for
  starlink.com and its subdomains.
- The release app finds its fonts and manufacturer table inside the app bundle.
