# Screens

All screenshots come from a debug build in anonymised mode (`debugAnonymize`). Device names, IP and
MAC addresses, the dish ID, the account and the location are replaced with sample values; the
telemetry is real.

## Menu bar

![Menu bar readouts](images/menubar.png)

The status item shows the readouts you pick in Settings → App: connection status, latency, ping
success, throughput and power draw. Click it to open the popover.

## Menu bar popover

![Popover](images/popover.png)

Click the menu bar item to open it. The top shows the Starlink name and connection state, with
buttons to pause polling and open the account. An alert card appears when the dish reports a
problem (here: partially obstructed) and links to the screen that explains it. The list opens
Statistics, Network, Obstructions, Alignment, Speed test, Satellites, the menu bar readouts and
Settings. **Open dashboard…** opens the large window.

## Dashboard

![Dashboard](images/dashboard.png)

The main window. The top row has tiles for download, upload, latency, power draw, ping success and
sky obstructed, each with a sparkline. Below it:

- **Throughput**: download and upload for the last 15 minutes.
- **Latency**: Starlink PoP ping with outages marked as red bands; 15 min, 1 h or 6 h; **Details…**
  opens the latency screen.
- **Power draw**, with an estimate of daily energy use.
- **Obstructions**: the dish's obstruction map drawn as a 3D dome you can orbit and zoom. The slider
  replays hourly snapshots; **Live satellite view** opens the satellite screen.
- **Events & outages** reported by the dish (obstructed, no pings, sky search and others) with
  durations.

The dock at the bottom opens the other panels.

## Statistics

![Statistics](images/statistics.png)

Cards in the style of the Starlink app: ping success, latency (median), power (average), throughput
(download average) and events. Each card opens its detail view.

## Latency detail

![Latency detail](images/latency.png)

Average, current and router latency, a chart of Starlink latency (white) against the router (orange)
for the selected window, and the distribution of both.

## Obstructions

![Obstructions](images/obstructions.png)

The dish's own obstruction map as a flat sky plot: clear, partial, obstructed and not yet seen
areas. It compares the share the dish reports with the share of the mapped sky that is blocked.

## Satellites

![Satellites](images/satellites.png)

Starlink satellites around the obstruction dome, computed on the Mac with SGP4 from CelesTrak's
orbital elements. It counts satellites in view and above 25°, and marks the **likely serving**
satellite with its elevation, azimuth and range. The dish does not report which satellite it uses,
so this is an estimate.

## Alignment

![Alignment](images/alignment.png)

Azimuth and elevation now and as wanted by the dish, pointing error and tilt. It uses the same rule
as the dish's web app: aligned while the pointing error stays under 5°.

## Speed test

![Speed test](images/speed-test.png)

Download and upload against Cloudflare with a speedometer. **Advanced** shows latency, jitter and
loss for the run, taken from the dish's own pings, and a **bufferbloat** grade: how much the average
latency rose while download and upload ran, compared with the 30 seconds before the test, graded A+
to F on [Waveform's scale](https://www.waveform.com/tools/bufferbloat). The test uses about 11 seconds each way and
counts against your data plan.

## Network: devices

![Devices](images/network-devices.png)

Every client of the Starlink router with live per-device download and upload, Wi-Fi band and a
**Paused** badge for paused devices.

### Device detail

![Device detail](images/device-detail.png)

Status, role, the node it is connected to, manufacturer (or "Private" for randomised MAC
addresses), band, signal strength, IP and MAC address, connection time and data this period.
**Pause…** blocks the device's internet until you resume it (requires Starlink sign-in). The
throughput history builds while the app is open and is kept in memory only.

## Network: nodes

![Nodes](images/nodes.png)

The router and any mesh nodes with their device counts, like the Starlink app. A link explains how
to add mesh coverage.

## Network: rules

![Rules](images/rules.png)

Rules group devices and act on them:

- **Schedule**: online only on certain days and hours.
- **Data limit**: a daily cap per device.
- **Timer**: a daily amount of online time.
- **DNS filter**: switch the whole network to a filtering DNS during a time window.

The header shows the router's current DNS and the home default. Without Starlink sign-in, rules
only report and do not pause devices. Rules act only while StarPulse is open. See
[DNS filtering](dns-filtering.md).

## Protect devices away from home

![DNS guide](images/dns-guide.png)

Step-by-step setup of DNSBunker or dnsforge on Apple devices (configuration profile), Android
(Private DNS) and browsers (secure DNS), with copy buttons.

## Settings

![Settings: Starlink](images/settings-starlink.png)

**Starlink**: snow melt, sleep schedule, software update window and deferral, as reported by the
dish. Maintenance actions are shown but not available in StarPulse.

![Settings: Router](images/settings-router.png)

**Router**: Wi-Fi networks and bands (the password is never shown), mesh nodes, firmware, DNS
servers, bypass mode and connection details. Maintenance actions are shown but not available.

![Settings: App](images/settings-app.png)

**App**: which readouts appear in the menu bar, opening the dashboard at launch, theme, the dish
address and the Starlink account.
