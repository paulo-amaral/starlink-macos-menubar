# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
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
