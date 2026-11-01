# License and attribution

TamaEmu is licensed under the **GNU General Public License v3.0** (see
[`LICENSE`](LICENSE)), for the whole repository — the iOS app (Swift/SwiftUI
code, Xcode project, widget extension) as well as the emulator core.

## Why the whole app is GPLv3, not just the core

The emulator core in [`Packages/TamaCore/Sources/CTama/`](Packages/TamaCore/Sources/CTama/)
was written by [maragotchi](https://github.com/maragotchi/tamaemu) and is used
here under its original license, GPLv3. That core is compiled as a static
library and linked directly into the TamaEmu app binary. Under GPLv3, a
binary that statically links GPL-licensed code is a combined/derivative work,
and the license requires the *entire* work to be conveyed under GPLv3 when
distributed as object code (§5c, §6). That's why this repository — not just
the `TamaCore` package — carries the GPLv3 `LICENSE` at its root: anyone who
receives a compiled `.ipa` of this app is entitled to the Corresponding
Source for all of it, under the same terms.

See [`Packages/TamaCore/CREDITS.md`](Packages/TamaCore/CREDITS.md) for the
itemized list of changes made to the upstream core for this iOS port (each
marked `// iOS port:` at the change site), as required by GPLv3 §5(a).

## What this repository does not grant rights to

- **Game firmware/ROM images** are not included, linked, or distributed by
  this project in any form, and nothing here grants any right to them. They
  remain the copyrighted property of their respective rights holders. Users
  must supply their own, obtained legally.
- **Trademarks** such as the names and likenesses of the physical devices
  this emulates are the property of their respective owners; this project
  is not affiliated with or endorsed by them.

## Getting the source

The Corresponding Source for any released build is this repository, at the
commit tagged with that release's version. Build instructions are in the
Xcode project (`TamaEmu.xcodeproj`) / `project.yml` (via `xcodegen`).

## Installing and updating

Releases are distributed as sideloaded `.ipa` files (not through the App
Store — see below) via an AltStore/SideStore-compatible source. Add the
source URL once in [AltStore](https://altstore.io) or
[SideStore](https://sidestore.io) and new versions will show up there as
updates; see those projects' own documentation for how sideloading and
source URLs work on your device.

### Maintaining the source on each release

[`apps.json`](apps.json) at the repo root is an AltStore/SideStore source,
served from https://github.com/Salvichito/tamaemu-ios. On every release:

1. Bump `CFBundleShortVersionString`/`CFBundleVersion` in `TamaEmu/Info.plist`.
2. Build and sign the `.ipa`, attach it to a new GitHub Release (tag it
   `vX.Y`).
3. In `apps.json`, append a new entry to `versions` (newest first) with the
   matching `version`, `date`, `downloadURL` (the Release asset URL), and
   `size` (the `.ipa`'s byte size), then commit.

Anyone who has already added the `apps.json` raw URL as a source in
AltStore/SideStore will see the new version as an update automatically —
no need to re-share anything.

Why not the App Store: Apple's Store terms impose additional restrictions on
recipients (e.g. limits on redistribution and modification) that conflict
with GPLv3 §10, which forbids imposing further restrictions on a covered
work. That conflict alone rules out App Store distribution for a GPLv3 app
like this one, regardless of Apple's current review policy on emulators.
Sideloading is therefore the license-compliant distribution path for this
project.
