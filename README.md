# TamaEmu

An iOS app that emulates Tamagotchi-family devices, built on the emulator
core from [maragotchi/tamaemu](https://github.com/maragotchi/tamaemu).

This project does **not** include, link to, or distribute any device
firmware/ROM. You need to supply your own, obtained legally.

## Installing

TamaEmu isn't on the App Store (see [NOTICE.md](NOTICE.md) for why) — it's
distributed as a sideloaded `.ipa` via an AltStore/SideStore source. If you
already use [AltStore](https://altstore.io) or [SideStore](https://sidestore.io),
add this source URL:

```
https://raw.githubusercontent.com/Salvichito/tamaemu-ios/main/apps.json
```

New releases will then show up as updates in the app automatically. If
you're not already set up with a sideloading tool, see AltStore's or
SideStore's own documentation for how to install one.

## Building from source

Requires Xcode 17+ and iOS 17 as the deployment target.

1. Open `TamaEmu.xcodeproj`.
2. Build and run the `TamaEmu` scheme on a simulator or device.

The emulator core lives in [`Packages/TamaCore`](Packages/TamaCore) as a
local Swift package.

## License and attribution

TamaEmu is licensed under the GNU GPLv3 — see [LICENSE](LICENSE) and
[NOTICE.md](NOTICE.md) for what that means for this repo, and
[`Packages/TamaCore/CREDITS.md`](Packages/TamaCore/CREDITS.md) for the
itemized changes made to the upstream emulator core for this iOS port.
