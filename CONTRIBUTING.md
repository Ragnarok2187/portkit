# Contributing to PortKit

Thanks for helping! PortKit is a small SwiftUI app with no dependencies, so getting started is quick.

## Set up

```bash
xcode-select --install     # or install Xcode
./build.sh                 # builds dist/PortKit.app
ARCHS=arm64 ./build.sh     # faster single-architecture build while iterating
```

Open `Package.swift` in Xcode if you prefer an IDE.

## Tests

- With Xcode: `swift test`
- With only the Command Line Tools: `Scripts/test-without-xcode.sh`

Logic that can be tested without a network or a Wine install (output parsing, executable ranking,
anti-cheat detection, launcher scripts) lives in plain functions. Please add a test when you change one.
CI runs the build and tests on every pull request.

## Guidelines

- **No credentials on the command line, in logs or on disk.** Passwords go to SteamCMD through a 0600
  runscript that is deleted right after.
- **Never bypass DRM or ownership checks.** PortKit only downloads games through Steam's own client and
  only works with games the user owns. Pull requests that add DRM bypasses, Steam emulators or similar
  will be closed.
- **Don't bundle third-party binaries in the repo.** SteamCMD, Wine and DXVK are downloaded at runtime from
  their publishers. D3DMetal can't be redistributed, so it must stay something users bring themselves.
- **Keep the UI plain-language.** Most users aren't Wine experts; error messages should say what to do next.
- **No `@State` or other SwiftUI macros.** They break builds with the Command Line Tools; use the `Box`
  pattern in `Views.swift` instead.

## Reporting a game

Open a "Game compatibility" issue with the App ID, your Mac, macOS version, the graphics backend you tried,
and the game's log (**Library → ⋯ → Open Log**).

## Regenerating the icon

```bash
swift Scripts/make-icon.swift Resources/AppIcon.icns
```
