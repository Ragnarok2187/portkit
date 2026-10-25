# Wine patches

PortKit installs a stock macOS Wine build from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds)
and, on Apple Silicon, replaces one file in it with a patched copy that ships inside PortKit.

## wow64cpu-rosetta2-workaround.patch

- **Problem:** [WineHQ bug 60494](https://bugs.winehq.org/show_bug.cgi?id=60494). Under Rosetta 2, 32-bit Windows
  programs crash or hang at random because Wine's 32→64-bit `ljmp` thunk in `wow64cpu.dll` sometimes runs in
  32-bit mode. In practice this hits during WineD3D's OpenGL setup, so most 32-bit Direct3D games (for example
  Batman: Arkham City) hang on a blank window or crash at startup.
  See also [Gcenx/macOS_Wine_builds#172](https://github.com/Gcenx/macOS_Wine_builds/issues/172).
- **Fix:** CodeWeavers' "CW HACK 20760" from CrossOver: when running under Rosetta 2, enter 64-bit code with
  `lcall` + `lretq` instead of `ljmp`. It only changes `dlls/wow64cpu/cpu.c` and only takes effect when the CPU
  reports itself as `VirtualApple` (Rosetta).
- **Origin:** CodeWeavers' CrossOver sources (LGPL 2.1 or later, like Wine). This copy of the diff is the one
  carried by [cashcon57/cauldron](https://github.com/cashcon57/cauldron) for Wine 11.x.
- **Binary:** `Resources/wow64cpu-<wine version>-rosetta.dll`, built from the official Wine source with this
  patch by `Scripts/build-wow64cpu.sh`. PortKit only installs it into a PortKit-managed Wine of that exact version,
  and keeps the original as `wow64cpu.dll.stock`.

## Updating Wine

1. Change `Wine.pinnedVersion` in `Sources/PortKit/Wine.swift`.
2. Run `WINE_VERSION=<new version> Scripts/build-wow64cpu.sh` and commit the new DLL.
3. Test a 32-bit game, then remove the old DLL from `Resources/`.

## License

Wine and this patch are licensed under the GNU LGPL 2.1 or later. The patched DLL is a modified Wine library;
its complete corresponding source is the Wine release named in its file name plus the patch in this folder.
