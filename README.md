# mac-utilities

Small, single-purpose Mac apps that live in the menu bar, or out of sight behind a shortcut. Each is its own app, released and
updated on its own, built from one Swift package.

| Utility                          | What it does                                                 |
| -------------------------------- | ------------------------------------------------------------ |
| [Calipers](Utilities/Calipers)   | Measure anything on screen, on every display (like PixelSnap). |

## Install

Download `<Name>.dmg` from the utility's latest [release](https://github.com/ckafrouni/mac-utilities/releases),
open it and drag the app to Applications. Apps are signed and notarized, and update themselves
(apps with a menu show "Update to X.Y.Z…"; the others install it on their own).

## Develop

Needs Xcode (Swift 6) on macOS 14 or later.

```sh
scripts/run.sh Calipers          # debug build, (re)started from build/Calipers.app
scripts/new-utility.sh Stopwatch timer 34C759   # a new utility: SF Symbol for its icons, icon color
swift scripts/make-icon.swift Calipers ruler.fill FF3373 -45   # redraw an app icon
scripts/build-app.sh Calipers    # universal release build, ad hoc signed
```

Dev builds use `<bundle id>.dev` and are signed with your Apple Development identity, so
permissions you grant them (Screen Recording, …) survive rebuilds and stay apart from the
installed app's.

## Release

From `main`: Actions → Release → Run workflow, or

```sh
gh workflow run release.yml -f utility=Calipers -f bump=patch   # or -f version=1.0.0
git tag calipers-v1.0.0 && git push origin calipers-v1.0.0     # or release a tagged commit
```

Releases are built by GitHub Actions, never on a Mac.

The workflow builds a universal app, signs it with the Developer ID, notarizes and staples it,
and publishes a GitHub Release tagged `<id>-vX.Y.Z` (`calipers-v0.1.0`) with `<Name>.dmg` to
install from and `<Name>.zip`, which installed copies update from. A
utility's first release is 0.1.0. Installed copies check the releases at launch and every 6
hours.

It needs these repository secrets:

| Secret             | What it is                                                                 |
| ------------------ | -------------------------------------------------------------------------- |
| `CSC_LINK`         | Base64 of the "Developer ID Application" certificate as a `.p12`.         |
| `CSC_KEY_PASSWORD` | That `.p12`'s password.                                                    |
| `APPLE_API_KEY`    | Contents of an App Store Connect API key (`AuthKey_XXXX.p8`).              |
| `APPLE_API_KEY_ID` | That key's ID.                                                             |
| `APPLE_API_ISSUER` | The issuer ID from App Store Connect → Users and Access → Integrations.    |

`scripts/build-app.sh <Name> --release X.Y.Z` does the same build locally, with the Developer ID
from your keychain and the key in `~/.otter-mail/signing`.
