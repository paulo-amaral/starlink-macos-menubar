# Contributing to StarPulse

Thanks for helping. Bug reports, fixes, docs and screenshots are all welcome.

## Set up

Requirements: macOS 14 or later, Xcode 16 or later (Swift 6).

```bash
git clone https://github.com/paulo-amaral/starlink-macos-menubar.git
cd starlink-macos-menubar
swift build            # compile
swift test             # unit tests (no Starlink hardware needed)
scripts/bundle.sh debug   # build/StarPulse.app for local testing
open build/StarPulse.app
```

`scripts/bundle.sh` signs ad hoc unless a local code-signing identity named
`StarPulse Local Signing` exists in your Keychain. A stable identity keeps the Keychain from asking
again after every build; see `docs/architecture.md#signing`.

### Optional live tests (read-only)

These talk to real hardware and never write to it:

```bash
STARPULSE_LIVE_NET=192.168.1.1 swift test   # your router's address; reads config, builds pause requests without sending
STARPULSE_LIVE_DIR=/path/to/captures swift test
```

## Pull requests

1. Open an issue first for anything larger than a small fix.
2. Keep changes focused; one topic per pull request.
3. Add or update tests for logic in `StarPulseCore`.
4. Run `swift test` and check the screens you touched in light and dark appearance.
5. Fill in the pull request template.

### Style

- Follow the existing code: Swift 6, SwiftUI, no new dependencies without discussion.
- Use the app's components (`AppButtonStyle`, `AppSegmented`, `CopyField`, `SheetHeader`) and the
  `Theme` type scale so every screen keeps the same fonts and colours.
- Comments explain *why*, not what.
- Protocol details from Dishylink keep their attribution comment.

### Screenshots and privacy

Never post screenshots that show device names, Wi-Fi names, account details, IDs or location.
Debug builds have an anonymised mode for documentation:

```bash
defaults write app.starpulse.mac debugAnonymize -bool true
```

### Writes to hardware

Code that changes a dish or router must re-read state before writing, change only what it means
to, verify the request, and be covered by unit tests on the request bytes. Do not test writes on
someone else's network.

## Code of conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md).
