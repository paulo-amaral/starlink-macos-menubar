# Security policy

## Supported versions

Only the latest release receives fixes.

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's private reporting:
**Security** tab → **Report a vulnerability** on this repository. Include the macOS version, the
StarPulse version, steps to reproduce and the impact you expect. You should get a first answer
within 7 days.

## How StarPulse handles your data

- **No Starlink password.** Signing in happens on the real starlink.com page inside the app. StarPulse
  only keeps the resulting session cookie, in the macOS **Keychain** (this Mac only, not synced).
- **Local network first.** Telemetry comes from the dish (`192.168.100.1:9201`) and router
  (`:9001`) over your LAN. The router's Wi-Fi password is never read, stored or displayed.
- **Minimal disk use.** Files written: the session cookie (Keychain), preferences, one fixed cache of
  orbital elements (about 1.8 MB, overwritten), up to 48 hourly obstruction snapshots (about 250 KB),
  and `rules.json` (rules and per-day byte counts, at most 40 days). No telemetry or browsing logs.
- **No analytics and no third-party SDKs.** The only outbound requests are to starlink.com (when
  signed in), CelesTrak (orbital elements, no location sent) and Cloudflare (speed test, only when
  you press Start).
- **Dish maintenance asks first.** Reboot and obstruction-map reset run only after you confirm. They
  go to the dish over the LAN, or through your signed-in account when the dish refuses local changes.
  Factory reset is not available in StarPulse.
- **Writes to your equipment are guarded.** Pausing a device or switching DNS goes through Starlink's
  authenticated cloud endpoint, an **unofficial, observed interface** that may change. Before sending,
  StarPulse checks that the router on the LAN is the router on your Starlink account (same device
  ID), re-reads it, resends every other device's settings byte for byte,
  verifies nothing else changed, and refuses to send otherwise. It never pauses the Mac it runs on,
  and DNS changes only happen between known presets.

## Code security practices

- CI builds and runs the unit tests on every pull request; CodeQL scans the Swift code.
- Pull requests must not add dependencies without discussion; the project currently has none.
- Never commit signing keys, cookies, `.env` files or screenshots that show personal data
  (see `CONTRIBUTING.md`).
