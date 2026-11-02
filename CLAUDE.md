# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Celsius is a macOS 15+ menu bar app that controls an LG ThinQ air conditioner through the official ThinQ Connect REST API, authenticated with a Personal Access Token. It is built with Swift Package Manager only (Swift 6.2 tools, strict concurrency). Command Line Tools are enough; there is no Xcode project.

## Commands

```sh
swift build                                   # debug build (fast compile check)
scripts/build-app.sh                          # release build, assembles and ad-hoc signs the .app bundle
scripts/build-app.sh --install                # also copies to /Applications and launches; saves $CELSIUS_PAT to the keychain if set
scripts/test.sh                               # run all tests
scripts/test.sh --filter StoreTests           # one suite
scripts/test.sh --filter ParsingTests/statusFromRealState   # one test
```

Always run tests through `scripts/test.sh`, not plain `swift test`. With only Command Line Tools installed, Swift Testing lives outside the default search paths, and the script adds the framework and rpath flags. Extra arguments are passed through to `swift test`.

### Checking UI changes visually

There are no SwiftUI previews. After changing the UI, render snapshots and look at the PNGs:

```sh
$(swift build --show-bin-path)/Celsius --snapshot <dir>   # popover in fixed states + airflow frames, no network
```

Each popover state is written twice: `<name>.png` (`ImageRenderer`, faithful for custom drawing but native AppKit controls show as yellow placeholders) and `<name>-native.png` (offscreen `NSHostingView`, shows switches, pop-ups and segmented controls, but drops scale/3D transforms and looks like an inactive window). Check custom drawing in the first and native controls in the second.

Snapshot rendering is not fully byte-deterministic (blur and gradients vary by 1–3/255 per channel), so compare images visually or with a tolerance, not with `cmp`.

Runtime env vars: `CELSIUS_PAT` (use this token instead of the keychain), `CELSIUS_OPEN_ON_LAUNCH=1` (open the popover on launch), `CELSIUS_LIVE_SNAPSHOT=<file.png>` (render the popover once live data loads).

## Architecture

There are two targets with a strict split:

- **`CelsiusCore`** (library, tested): the API client, models, settings/keychain and the observable store. It has no SwiftUI and no AppKit UI.
- **`Celsius`** (executable): the AppKit shell (a `main` entry point, an app delegate, an `NSStatusItem` with an `NSPopover` hosting SwiftUI) plus all the views. It is an accessory app (`LSUIElement`), with no Dock icon and no windows.

### Data flow

- One `@MainActor @Observable` store is the single source of truth. Views read from it and call its methods; they never keep their own copy of device state. The menu bar label observes the same store through `withObservationTracking`, re-registering on every change.
- **Optimistic overrides.** The cloud takes seconds to reflect a command. The UI shows *server state with pending overrides applied*. Each override expires after a fixed lifetime or is dropped once the polled server state already matches it. Confirmation is checked by applying the command to the server state and seeing that nothing changes.
- **Command queue.** Commands go out one at a time through a single worker task. A newer command for the same field replaces an unsent one, so "field" is the coalescing key. Re-sending the current value is skipped, because the API rejects redundant power commands. The −/+ temperature steps are debounced; slider drags commit on release.
- **Polling** is faster while the popover is visible and slower in the background. It stops while the Mac sleeps and restarts on wake.
- All timings (override lifetime, debounce, refresh delays, message duration, poll intervals) are named static constants on the store. Add new ones there instead of inline literals.

### ThinQ API conventions

- Device state and profile documents vary per model, so they are decoded into a loosely typed JSON enum and then read defensively into flat Swift structs. Missing data falls back to sensible defaults. Capabilities come from the profile's *writable* properties, with a static fallback when the profile is empty.
- Commands are an enum. Each case knows its coalescing field, its JSON payload (`{resource: {property: value}}`), and how it changes a local status (`applying`). When you add a command, all three must be updated together.
- API values such as job modes and fan speeds stay raw strings so unknown values survive. Display names, icons and colors are mapped in the UI layer.
- The host is fixed to the Americas region (`api-aic`). `x-country` is the account country from settings (`ThinQClient.countries`, Brazil by default). The `x-api-key` in the client is LG's public, SDK-wide key, not a secret. The user's PAT lives only in the login keychain (service `com.gabrielvillarinho.celsius`).
- API error codes are mapped to a small error enum that drives connection state: unauthorized → setup prompt, offline/network → offline state, everything else → a transient footer message.
- The sleep timer counts down from when the device accepts it, so the minutes left are bucketed up to whole hours (95 min → the 2 h timer). Use the status's computed bucket instead of redoing the math.

### Testability seams

- The HTTP client takes an injectable `@Sendable` transport closure. The store takes a client factory, a clock (`now`) and a settings protocol. Tests use in-memory settings and a fake transport; they never touch the keychain or the network.
- Test fixtures are real API responses from the unit, with the device ID replaced. Prefer adding fixtures over hand-written JSON when covering new fields.
- The store has a preview initializer with fixed data that never polls or sends. Snapshots use it.
- Tests use Swift Testing (`@Suite` structs, `@Test`, `#expect`, parameterized `arguments:`), not XCTest.

### UI conventions

- The popover is dark-only and fixed width, with design tokens (colors, radii, opacities) and a shared `.card()` modifier (used by Settings) in the theme. Accents follow the system accent color. Use tokens instead of color or size literals, and keep API-value → label/icon mapping in the labels helper.
- Animated drawing is a pure function of time. `TimelineView` + `Canvas` with a renderer struct that takes the date, so snapshots can freeze time via a `fixedDate` input. The timeline pauses when the popover is hidden or motion isn't needed, and respects Reduce Motion.
- Speed changes in the airflow keep phase continuity through an anchor/phase clock instead of restarting.
- Delayed view-local state changes use `.task(id:)`, so the previous wait is cancelled; avoid detached `Task {}` sleeps in `onChange`.
- The main screen follows macOS Control Center: native switch, segmented control and pop-up buttons, Control Center–style round toggles, and a menu-item row for settings. Prefer native controls over custom-drawn ones.
- SwiftUI's menu `Picker` sizes itself to its longest option and ignores `.frame(width:)`, and the segmented `Picker` keeps its intrinsic width, so these use the `NSPopUpButton` / `NSSegmentedControl` wrappers, which honor the proposed width.

## Agents and skills

The project ships three pinned, installed skills: `swiftui-expert-skill`, `write-swift` and `apple-design`. `apple-design` is web-oriented, so translate its principles into SwiftUI APIs instead of copying its JS. Load the relevant ones before writing Swift or SwiftUI. The `swiftui-engineer` subagent preloads all three. Installed skills are vendored third-party content; update them through the skills tooling, never by hand-editing.
