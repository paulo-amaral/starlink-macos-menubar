#!/bin/zsh
# Builds StarPulse.app into ./build. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
config=${1:-release}
# Universal binary: Apple silicon and Intel Macs.
arch=(--arch arm64 --arch x86_64)
swift build -c "$config" $arch
bin=$(swift build -c "$config" $arch --show-bin-path)
app=build/StarPulse.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/StarPulse" "$app/Contents/MacOS/StarPulse"
cp Sources/StarPulse/Info.plist "$app/Contents/Info.plist"
# Resources go straight into Contents/Resources (found through Bundle.main); SwiftPM's own
# .bundle folders would have to sit in the app root, which code signing rejects.
# Multi-arch builds (xcbuild) nest the files in Contents/Resources; single-arch builds do not.
resources() { [[ -d "$bin/$1/Contents/Resources" ]] && echo "$bin/$1/Contents/Resources" || echo "$bin/$1" }
cp -R "$(resources StarPulse_StarPulse.bundle)/Fonts" "$app/Contents/Resources/"
cp "$(resources StarPulse_StarPulseCore.bundle)/oui.json" "$app/Contents/Resources/"
# Icon drawn by scripts/make-icon.swift; regenerate with: swift scripts/make-icon.swift /tmp/AppIcon.iconset && iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# A stable local identity keeps the app's Keychain access ("Always Allow") valid across builds.
# Created once on this Mac (self-signed, not an Apple certificate); without it, sign ad hoc.
identity="StarPulse Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$identity\""; then
    codesign --force --deep --sign "$identity" "$app"
else
    codesign --force --deep --sign - "$app"
fi
echo "Built $app"
