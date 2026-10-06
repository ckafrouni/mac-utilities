# mac-utilities

One-off Mac menu bar utilities, each its own app, in one Swift package. See README.md for
running, building and releasing.

## Layout

- `Utilities/<Name>/`: one app. `Sources/` is its executable target (found by `Package.swift`
  on its own; no manifest edits), `Info.plist` its bundle (`LSUIElement`, bundle ID
  `com.ckafrouni.<id>`), `README.md` what it does, `Resources/` (optional) copied into the bundle.
- `Shared/UtilityKit/`: what every utility shares: `UtilityApp` (`run`: the status item and its
  menu, with Check for Updates, Open at Login and Quit; `runInBackground`: no icon, reached by
  shortcut, opens at login and updates itself), `HotKey` (global shortcuts, Carbon, no
  Accessibility permission), `LoginItem`, `Updater` (GitHub Releases of this repo).
- `scripts/`: `run.sh` (dev), `build-app.sh` (bundle, sign, notarize), `new-utility.sh`,
  `next-version.sh` (release tags).
- `.github/workflows/`: `ci.yml` builds every utility; `release.yml` releases one.

## Conventions

- A utility is the smallest thing that does its job well: AppKit, no dependencies, no settings
  window unless it needs one. Start one with `scripts/new-utility.sh <Name> [symbol]`.
- Version comes from the release (`<id>-vX.Y.Z` tags); `Info.plist` says 0.0.0, which is what
  dev builds are (they don't update).
- Swift 5 language mode, macOS 14+. UI code is `@MainActor`.
- Anything on screen works on every display: use global AppKit coordinates and each
  `NSScreen`'s own frame and backing scale; never assume the main screen.

## Verifying

`swift build`, then `scripts/run.sh <Name>` and try the change in the app. Releases are signed
by Christophe's Developer ID (team 838JVGY7W4).
