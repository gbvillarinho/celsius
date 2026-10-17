# Celsius

[![Release](https://img.shields.io/github/v/release/gbvillarinho/celsius?style=flat-square)](https://github.com/gbvillarinho/celsius/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/gbvillarinho/celsius/total?style=flat-square)](https://github.com/gbvillarinho/celsius/releases)
[![Build](https://img.shields.io/github/actions/workflow/status/gbvillarinho/celsius/release.yml?style=flat-square&label=build)](https://github.com/gbvillarinho/celsius/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/github/license/gbvillarinho/celsius?style=flat-square)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)
![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white)
[![Stars](https://img.shields.io/github/stars/gbvillarinho/celsius?style=flat-square)](https://github.com/gbvillarinho/celsius/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/gbvillarinho/celsius?style=flat-square)](https://github.com/gbvillarinho/celsius/commits/main)

Control your LG air conditioner from the Mac menu bar. Click the icon, pick a temperature, mode or fan
speed, and that's it. No phone needed.

<p align="center">
  <img src="docs/demo.gif" alt="The Celsius popover in the macOS menu bar" width="560">
</p>

## What it does

- Turns the air conditioner on and off
- Changes the mode (cool, fan, dry, auto)
- Sets the temperature, with a range you choose
- Sets the fan speed and the air swing
- Turns Eco mode on and off
- Sets a sleep timer that turns the unit off after a few hours
- Opens when you log in, if you want it to

## What you need

- A Mac running macOS 15 or later
- An LG air conditioner that already works in the LG ThinQ phone app
- An LG account in Brazil or another country in LG's Americas region (the app was built and tested in Brazil)

## Install

1. Go to the [Releases page](https://github.com/gbvillarinho/celsius/releases/latest).
2. Download `Celsius.zip`.
3. Double-click it to unzip, then drag Celsius into your Applications folder.
4. Open Celsius. Its icon shows up in the menu bar.

### Let an AI install it

If you have an assistant that can run commands on your Mac, such as
[Claude Code](https://claude.com/claude-code), copy this prompt into it. The same prompt works for
updating, because it replaces any older copy.

```text
Install or update the Celsius menu bar app on this Mac.

1. If Celsius is running, quit it (pkill -x Celsius).
2. Download Celsius.zip from the latest release at
   https://github.com/gbvillarinho/celsius/releases/latest
   (for example: gh release download --repo gbvillarinho/celsius --pattern Celsius.zip)
3. Unzip it and move Celsius.app into /Applications, replacing any older copy.
4. Remove the quarantine flag so macOS opens it without a warning:
   xattr -dr com.apple.quarantine /Applications/Celsius.app
5. Open the app.

If this is a first install, tell me to paste my LG access token in the Celsius Settings screen.
Do not ask for my token and do not run anything else.
```

Don't give your LG token to the assistant. Paste it into the app yourself.

### If macOS won't open the app

The first time, macOS may say it can't verify the app. That happens with any app that isn't from the
App Store. To open it anyway:

1. Right-click Celsius in Applications and choose Open.
2. Click Open in the window that appears.

If you don't see that option, go to System Settings > Privacy & Security, scroll down, and click
Open Anyway next to Celsius. You only have to do this once.

## Connect your air conditioner

Celsius needs a free access token from LG to talk to your air conditioner. It takes about a minute.

### 1. Get a token

1. Open [connect-pat.lgthinq.com](https://connect-pat.lgthinq.com) and sign in with your LG account.
2. Create a new token (LG calls it a Personal Access Token).
3. Copy it. It starts with `thinqpat_`.

### 2. Paste it into Celsius

1. Click the Celsius icon in the menu bar. With no token yet, it opens on Settings.
2. Paste the token (the clipboard button next to the field does it for you) and click Connect.
3. Your air conditioner appears and you can control it.

If your LG account isn't from Brazil, pick its country under Account country in Settings.

The token is stored in your Mac's Keychain, on this Mac only. It is never written to a file and
never sent anywhere except LG.

## Updating

Celsius checks for a new version about once a day. When there is one, a blue dot appears next to
"Air conditioner settings..." in the popover. Open Settings and click "Update to X.Y.Z", which takes you
to the download page. Download the zip and replace the app in Applications, the same as the first time.
Your token stays in the Keychain.

Or let an AI assistant do it. Paste this prompt into one that can run commands on your Mac, such as
[Claude Code](https://claude.com/claude-code). It's the same prompt as the install one, and it replaces
the old copy.

```text
Install or update the Celsius menu bar app on this Mac.

1. If Celsius is running, quit it (pkill -x Celsius).
2. Download Celsius.zip from the latest release at
   https://github.com/gbvillarinho/celsius/releases/latest
   (for example: gh release download --repo gbvillarinho/celsius --pattern Celsius.zip)
3. Unzip it and move Celsius.app into /Applications, replacing any older copy.
4. Remove the quarantine flag so macOS opens it without a warning:
   xattr -dr com.apple.quarantine /Applications/Celsius.app
5. Open the app.

If this is a first install, tell me to paste my LG access token in the Celsius Settings screen.
Do not ask for my token and do not run anything else.
```

macOS may ask for your Keychain password once after an update, so the new copy can read your token.
Click Always Allow. If the app says it has no token, paste it again in Settings.

## Questions

**"LG rejected this token."**
The token is wrong or has expired. Create a new one on the LG page and paste it in Settings.

**Nothing changes right after I press a button.**
LG's servers take a few seconds to confirm a change. Celsius shows the new value right away and checks
it a moment later.

**Does it work in other countries?**
In the Americas, probably: pick your account's country under Account country in Settings. It has only
been tested in Brazil. Accounts outside the Americas use other LG servers and aren't supported yet.

**Does it work with any LG air conditioner?**
It was built and tested with one model. Others should work, but some controls may be missing or behave
differently.

**How do I disconnect or switch accounts?**
Open Settings in the app, click Sign out, then paste a new token.

---

## For developers

Celsius is a Swift Package (no Xcode project). You only need the Command Line Tools
(`xcode-select --install`) and Swift 6.2 or later.

Build and install from source:

```sh
git clone https://github.com/gbvillarinho/celsius.git
cd celsius
scripts/build-app.sh --install    # build, ad-hoc sign, copy to /Applications and launch
```

Use `scripts/build-app.sh` without `--install` to only build `build/Celsius.app`. To install with the
token already in the Keychain: `CELSIUS_PAT=thinqpat_your_token scripts/build-app.sh --install`.

Build and test:

```sh
swift build                           # debug build
scripts/test.sh                       # all tests
scripts/test.sh --filter StoreTests   # one suite
```

Always run tests through `scripts/test.sh`. With only Command Line Tools installed, Swift Testing lives
outside the default search paths, and the script adds the flags it needs.

Environment variables for running from the terminal:

| Variable | Effect |
| --- | --- |
| `CELSIUS_PAT=<token>` | use this token instead of the Keychain |
| `CELSIUS_OPEN_ON_LAUNCH=1` | open the popover on launch |
| `CELSIUS_LIVE_SNAPSHOT=<file.png>` | render the popover with live data once it loads |

To check UI changes without running the app, render the popover in fixed states (no network):

```sh
$(swift build --show-bin-path)/Celsius --snapshot <dir>
```

Layout:

- `Sources/CelsiusCore`: API client, models, settings/Keychain and the observable store (tested)
- `Sources/Celsius`: the AppKit + SwiftUI app (status item, popover and views)
- `Tests/CelsiusCoreTests`: Swift Testing suites; fixtures are real responses from the unit, with the device ID replaced

The app uses LG's official [ThinQ Connect API](https://connect-pat.lgthinq.com) with a Personal Access
Token. The host is LG's Americas one (`api-aic.lgthinq.com`) and `x-country` is the account country
chosen in Settings (Brazil by default); a country from another region would also need its host in
`ThinQClient`. See [CLAUDE.md](CLAUDE.md) for architecture details and conventions.

## License

[MIT](LICENSE). Celsius is not affiliated with or endorsed by LG Electronics.
