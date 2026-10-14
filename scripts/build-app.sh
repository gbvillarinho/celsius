#!/usr/bin/env bash
# Builds Celsius.app into build/. Pass --install to copy it to /Applications, save the LG token
# from $CELSIUS_PAT in the keychain (if set) and launch it.
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Celsius.app
swift build -c release --product Celsius
BIN="$(swift build -c release --show-bin-path)/Celsius"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Celsius"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the latest tag as the version, so a local build doesn't look outdated to the update check.
if VERSION="$(git describe --tags --abbrev=0 2>/dev/null)"; then
  VERSION="${VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi
if [[ ! -f Resources/AppIcon.icns ]]; then
  scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - --timestamp=none "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Celsius 2>/dev/null || true
  rm -rf /Applications/Celsius.app
  cp -R "$APP" /Applications/Celsius.app
  if [[ -n "${CELSIUS_PAT:-}" ]]; then
    security add-generic-password -U -s com.gabrielvillarinho.celsius -a thinq-pat \
      -l "Celsius – LG ThinQ token" -w "$CELSIUS_PAT" -T /Applications/Celsius.app
    echo "Saved the LG token in the keychain"
  fi
  open /Applications/Celsius.app
  echo "Installed /Applications/Celsius.app"
fi
