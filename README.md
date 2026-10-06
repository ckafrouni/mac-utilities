# mac-utilities

Small, single-purpose Mac apps that live in the menu bar. Each is its own app, released and
updated on its own, built from one Swift package.

| Utility                          | What it does                                                 |
| -------------------------------- | ------------------------------------------------------------ |
| [Calipers](Utilities/Calipers)   | Measure anything on screen, on every display (like PixelSnap). |

## Install

Download `<Name>.zip` from the utility's latest [release](https://github.com/ckafrouni/mac-utilities/releases),
unzip it and move the app to Applications. Apps are signed and notarized, and update themselves
(the menu shows "Update to X.Y.Z…" when there's a new release).

## Develop

Needs Xcode (Swift 6) on macOS 14 or later.

```sh
scripts/run.sh Calipers          # debug build, (re)started from build/Calipers.app
scripts/new-utility.sh Stopwatch timer   # a new utility, with an SF Symbol for its menu bar icon
scripts/build-app.sh Calipers    # universal release build, ad hoc signed
```

Dev builds use `<bundle id>.dev` and are signed with your Apple Development identity, so
permissions you grant them (Screen Recording, …) survive rebuilds and stay apart from the
installed app's.

## Release

From `main`: Actions → Release → Run workflow, or

```sh
gh workflow run release.yml -f utility=Calipers -f bump=patch   # or -f version=1.0.0
```

The workflow builds a universal app, signs it with the Developer ID, notarizes and staples it,
and publishes a GitHub Release tagged `<id>-vX.Y.Z` (`calipers-v0.1.0`) with `<Name>.zip`. A
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
