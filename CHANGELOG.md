# Changelog

All notable changes are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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
