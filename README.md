<p align="center"><img src="docs/icon.png" width="128" alt="PortKit icon"></p>

<h1 align="center">PortKit</h1>

<p align="center">Play the Windows versions of your Steam games on a Mac, one double-click app per game.</p>

---

PortKit signs in to Steam, downloads the **Windows** build of games you own, and wraps each game in a
regular macOS `.app` (with its own icon) that runs it through [Wine](https://www.winehq.org). Under the hood
it uses the same approach as CrossOver and Whisky: Windows API calls are translated to macOS while the game
runs, and DirectX is translated to Metal.

> PortKit is an independent project. It is not affiliated with, endorsed by, or sponsored by Valve Corporation.
> Steam is a trademark of Valve Corporation. You can only download games your Steam account owns.

## Features

- **Search the Steam store** by name or App ID, filtered to Windows-only games.
- **Downloads through Valve's official SteamCMD.** Your password goes straight to SteamCMD, is passed
  through a private temporary file (never the command line), and is never saved. Steam Guard codes and Steam
  Mobile approval are supported.
- **One click to set up everything else:** Wine, DXVK and a Windows prefix are downloaded for you.
- **A real Mac app for every game** in `~/Applications/PortKit Games`, with the store art as its icon.
  Put it in the Dock or open it from Spotlight.
- **Two graphics backends per game:** WineD3D (OpenGL, most compatible) or DXVK (Vulkan → Metal through
  MoltenVK, faster for DirectX 10–11 games).
- **Steamworks support:** an optional Windows Steam client in the prefix, started automatically before the
  game, for titles that need achievements, DRM or multiplayer.
- **Compatibility warnings:** PortKit detects kernel anti-cheat (Easy Anti-Cheat, BattlEye and others) and
  Steamworks requirements, and tells you before you hit Play.
- **Per-game settings:** pick the executable, launch options, graphics backend and Steam start-up behavior.
- **Updates and repair:** check for game updates or verify game files from the Library.
- **Retina mode**, a per-game launch log, and a full activity log you can copy into bug reports.

## Requirements

- macOS 14 Sonoma or later, on Apple Silicon or Intel
- [Rosetta 2](https://support.apple.com/en-us/102527) on Apple Silicon (PortKit offers to install it)
- About 300 MB for the tools, plus room for your games

## Install

1. Download `PortKit.zip` from the [latest release](https://github.com/Ragnarok2187/portkit/releases/latest) and unzip it.
2. Move **PortKit.app** to your Applications folder.
3. The first time, macOS will say PortKit "can't be opened" because it isn't notarized by Apple (that needs a
   paid developer account). Open **System Settings → Privacy & Security**, scroll down and click
   **Open Anyway**. Alternatively, run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/PortKit.app
   ```

## Use

1. **Setup** → **Install Everything**. This downloads SteamCMD, Wine, DXVK and creates the Windows prefix
   (a few minutes).
2. **Setup** → sign in with your Steam username and password. Enter a Steam Guard code if asked, or
   approve the sign-in in the Steam Mobile app.
3. **Get Games** → search for a game → **Install & Port**.
4. **Library** → **Play**, or open the game from `~/Applications/PortKit Games`.

If a game doesn't start, open **Library → ⋯ → Open Log**, try the other graphics backend under
**Settings…**, or install the Windows Steam client from Setup (needed by most games that show the
"Steamworks" tag).

## What PortKit can't do

These are limits of translation itself, not of this app:

- **It doesn't recompile games into native Mac code.** That requires the game's source code. PortKit
  translates the Windows build at runtime, which is how every Windows-on-Mac compatibility tool works.
- **Kernel-level anti-cheat** (Easy Anti-Cheat in kernel mode, BattlEye, Vanguard, and similar) refuses to run
  under Wine. PortKit warns you when it detects one.
- **DirectX 12** needs Apple's D3DMetal. Apple's license doesn't allow redistributing it, so PortKit can't
  bundle it. If you install Apple's
  [Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/) or another Wine build that
  includes D3DMetal, point **Setup → Wine → Choose…** at its `wine` binary and PortKit will use it.
- **Rosetta 2:** the Wine builds are Intel code. Apple has said Rosetta will stay available for older games
  after it is phased out for general apps, but check Apple's current guidance for your macOS version.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`) or Xcode.

```bash
git clone https://github.com/Ragnarok2187/portkit.git
cd portkit
./build.sh                # universal app in dist/PortKit.app
open dist/PortKit.app
```

Run the tests with `swift test` (needs full Xcode) or `Scripts/test-without-xcode.sh` (Command Line Tools
only).

## How it works

| Piece | What it does | Source |
| --- | --- | --- |
| [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) | Signs in and downloads Windows depots (`@sSteamCmdForcePlatformType windows`) | Valve, downloaded at first run |
| [Wine](https://www.winehq.org) | Runs Windows programs on macOS | [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) (LGPL), downloaded at first run |
| [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) + [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | DirectX 10–11 → Vulkan → Metal | zlib / Apache 2.0, downloaded at first run |
| PortKit | Store search, setup, executable detection, `.app` generation, per-game settings | This repo (MIT) |

Code layout (`Sources/PortKit`):

- `SteamCMD.swift`: sign-in, downloads, output parsing and retries
- `SteamStore.swift`: public store search and app details
- `Wine.swift`: Wine/DXVK install, prefix management, PE header parsing
- `Porter.swift`: main-executable detection, compatibility checks, `.app` and launcher generation
- `AppModel.swift`, `Views.swift`: SwiftUI app

Data lives in `~/Library/Application Support/PortKit`, logs in `~/Library/Logs/PortKit`, and generated apps
in `~/Applications/PortKit Games`.

## Contributing

Bug reports, game compatibility reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
