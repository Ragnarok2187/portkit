import Foundation

/// Locates or installs a macOS Wine build and manages the shared Windows prefix.
enum Wine {
    /// A user-chosen wine binary (e.g. from Game Porting Toolkit or Whisky) wins.
    static func locate() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: "customWine"), fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let bundled = findWineBinary(in: Paths.wineDir) { return bundled }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Wine Stable.app/Contents/Resources/wine/bin/wine",
            "/Applications/Wine Staging.app/Contents/Resources/wine/bin/wine",
            "/Applications/Wine Devel.app/Contents/Resources/wine/bin/wine",
            "\(home)/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/bin/wine64",
            "/opt/homebrew/bin/wine", "/usr/local/bin/wine", "/usr/local/bin/wine64",
        ]
        return candidates.first(where: fm.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func findWineBinary(in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        var wine: URL?
        for case let url as URL in e where url.deletingLastPathComponent().lastPathComponent == "bin" {
            if url.lastPathComponent == "wine64" { return url }   // older split 32/64-bit builds
            if url.lastPathComponent == "wine" { wine = url }
        }
        return wine
    }

    static func wineserver(for wine: URL) -> URL {
        wine.deletingLastPathComponent().appendingPathComponent("wineserver")
    }

    /// Wine for macOS ships as x86_64, so Apple Silicon needs Rosetta 2.
    static func rosettaAvailable() async -> Bool {
        #if arch(arm64)
        return await ProcessRunner.capture("/usr/bin/arch", ["-x86_64", "/usr/bin/true"]).0 == 0
        #else
        return true
        #endif
    }

    /// Downloads the latest Gcenx macOS Wine build (includes MoltenVK for Vulkan/DXVK).
    static func install(log: @escaping @Sendable (String) -> Void) async throws {
        let rel = try await Net.latestRelease("Gcenx/macOS_Wine_builds")
        let pick = ["wine-stable", "wine-staging", "wine-devel"].lazy.compactMap { flavor in
            rel.assets.first { $0.name.hasPrefix(flavor) && $0.name.hasSuffix(".tar.xz") }
        }.first
        guard let asset = pick else { throw PortKitError("No macOS Wine build found in release \(rel.tag_name).") }
        let staging = Paths.support.appendingPathComponent("wine-download", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        Paths.ensure(staging)
        let tar = staging.appendingPathComponent(asset.name)
        log("Downloading \(asset.name) (about 200 MB)…")
        try await Net.download(asset.browser_download_url, to: tar)
        log("Extracting…")
        let status = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xJf", tar.path, "-C", staging.path], onLine: log)
        try? FileManager.default.removeItem(at: tar)
        guard status == 0, findWineBinary(in: staging) != nil else {
            try? FileManager.default.removeItem(at: staging)
            throw PortKitError("Wine extraction failed.")
        }
        // Swap in only after a complete extraction so a failed update never breaks a working install.
        try? FileManager.default.removeItem(at: Paths.wineDir)
        try FileManager.default.moveItem(at: staging, to: Paths.wineDir)
        await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", Paths.wineDir.path])
        log("Wine \(rel.tag_name) installed.")
    }

    static var env: [String: String] {
        ["WINEPREFIX": Paths.prefix.path, "WINEDEBUG": "-all", "WINEMSYNC": "1", "WINEESYNC": "1"]
    }

    static var prefixReady: Bool {
        FileManager.default.fileExists(atPath: Paths.prefix.appendingPathComponent("system.reg").path)
    }

    @discardableResult
    static func run(_ wine: URL, _ args: [String], extraEnv: [String: String] = [:], cwd: URL? = nil,
                    log: @escaping @Sendable (String) -> Void) async -> Int32 {
        await ProcessRunner.run(wine, args, env: env.merging(extraEnv) { _, n in n }, cwd: cwd, onLine: log)
    }

    static func waitForServer(_ wine: URL, log: @escaping @Sendable (String) -> Void) async {
        await ProcessRunner.run(wineserver(for: wine), ["-w"], env: env, onLine: log)
    }

    static func initPrefix(_ wine: URL, log: @escaping @Sendable (String) -> Void) async throws {
        Paths.ensure(Paths.prefix)
        log("Creating Windows prefix (takes a minute)…")
        // Skip Wine's interactive "install Mono/Gecko?" dialogs; games that need .NET can add it from Setup.
        await run(wine, ["wineboot", "--init"], extraEnv: ["WINEDLLOVERRIDES": "mscoree,mshtml="], log: log)
        await waitForServer(wine, log: log)
        guard prefixReady else { throw PortKitError("Prefix creation failed. See Activity for details.") }
        await setRetina(wine, enabled: UserDefaults.standard.bool(forKey: "retinaMode"), log: log)
        log("Prefix ready.")
    }

    /// Renders games at full Retina resolution instead of scaled-up points.
    static func setRetina(_ wine: URL, enabled: Bool, log: @escaping @Sendable (String) -> Void) async {
        await run(wine, ["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ",
                         "/d", enabled ? "y" : "n", "/f"], log: log)
        await waitForServer(wine, log: log)
    }

    /// Many Steam games call SteamAPI_Init(), which needs the Windows Steam client running in the same prefix.
    static func installWindowsSteam(_ wine: URL, log: @escaping @Sendable (String) -> Void) async throws {
        let setup = Paths.support.appendingPathComponent("SteamSetup.exe")
        log("Downloading Windows Steam installer…")
        try await Net.download(URL(string: "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!, to: setup)
        log("Installing Windows Steam into the prefix…")
        await run(wine, [setup.path, "/S"], log: log)
        await waitForServer(wine, log: log)
        try? FileManager.default.removeItem(at: setup)
        guard FileManager.default.fileExists(atPath: Paths.windowsSteamExe.path) else {
            throw PortKitError("Windows Steam didn't install. See Activity for details.")
        }
        log("Windows Steam installed. Open it once and sign in.")
    }

    static var windowsSteamDir: URL { Paths.windowsSteamExe.deletingLastPathComponent() }

    /// Windows Steam records accounts that have signed in on this "PC" in loginusers.vdf.
    static var windowsSteamSignedIn: Bool {
        let file = windowsSteamDir.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("\"AccountName\"")
    }

    /// Reads a top-level string value (e.g. "installdir") from a Steam .acf/.vdf file.
    static func vdfValue(_ key: String, in text: String) -> String? {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s+\"([^\"]*)\""
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Makes Windows Steam see a SteamCMD-downloaded game as installed, by copying its app manifest
    /// and linking steamapps/common/<installdir> to the game folder. Games with Steam DRM must be
    /// started by the Steam client itself (or they show "Application load error P:0000065432").
    static func registerWithWindowsSteam(appID: Int, name: String, installDir: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.windowsSteamExe.path) else {
            throw PortKitError("Install Steam for Windows on the Setup page first.")
        }
        let steamapps = windowsSteamDir.appendingPathComponent("steamapps", isDirectory: true)
        let common = steamapps.appendingPathComponent("common", isDirectory: true)
        try fm.createDirectory(at: common, withIntermediateDirectories: true)

        let source = installDir.appendingPathComponent("steamapps/appmanifest_\(appID).acf")
        var manifest = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        var folder = vdfValue("installdir", in: manifest) ?? ""
        if folder.isEmpty || folder.contains("/") || folder.contains("..") {
            folder = name.fileSafe
            manifest = """
            "AppState"
            {
            \t"appid"\t\t"\(appID)"
            \t"Universe"\t\t"1"
            \t"name"\t\t"\(name.replacingOccurrences(of: "\"", with: ""))"
            \t"StateFlags"\t\t"4"
            \t"installdir"\t\t"\(folder)"
            }

            """
        }
        try manifest.write(to: steamapps.appendingPathComponent("appmanifest_\(appID).acf"), atomically: true, encoding: .utf8)

        let link = common.appendingPathComponent(folder)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: link.path), existing == installDir.path { return }
        if (try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            try fm.removeItem(at: link)
        } else if fm.fileExists(atPath: link.path) {
            throw PortKitError("Windows Steam already has a folder named “\(folder)”. Remove it and try again.")
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: installDir)
    }

    // MARK: DXVK (DirectX 10/11 → Vulkan → Metal via MoltenVK)

    static let dxvkDLLs = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]

    static var dxvkInstalled: Bool { dxvkFolder(for: .x64) != nil }

    static func dxvkFolder(for arch: PEArch) -> URL? {
        guard let e = FileManager.default.enumerator(at: Paths.dxvkDir, includingPropertiesForKeys: nil) else { return nil }
        let want = arch == .x64 ? "x64" : "x32"
        for case let url as URL in e where url.lastPathComponent == want {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("d3d11.dll").path) { return url }
        }
        return nil
    }

    static func installDXVK(log: @escaping @Sendable (String) -> Void) async throws {
        let rel = try await Net.latestRelease("Gcenx/DXVK-macOS")
        guard let asset = rel.assets.first(where: { $0.name.hasSuffix(".tar.gz") && !$0.name.contains("builtin") })
                ?? rel.assets.first(where: { $0.name.hasSuffix(".tar.gz") }) else {
            throw PortKitError("No DXVK build found in release \(rel.tag_name).")
        }
        try? FileManager.default.removeItem(at: Paths.dxvkDir)
        Paths.ensure(Paths.dxvkDir)
        let tar = Paths.dxvkDir.appendingPathComponent(asset.name)
        log("Downloading \(asset.name)…")
        try await Net.download(asset.browser_download_url, to: tar)
        await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", tar.path, "-C", Paths.dxvkDir.path], onLine: log)
        try? FileManager.default.removeItem(at: tar)
        guard dxvkInstalled else { throw PortKitError("DXVK extraction failed.") }
        log("DXVK \(rel.tag_name) installed.")
    }
}

enum PEArch: String, Codable { case x86, x64, unknown }

extension PEArch {
    /// Reads the machine field of a Windows PE executable header.
    static func of(_ exe: URL) -> PEArch {
        guard let h = try? FileHandle(forReadingFrom: exe) else { return .unknown }
        defer { try? h.close() }
        guard let dos = try? h.read(upToCount: 64), dos.count == 64, dos[0] == 0x4D, dos[1] == 0x5A else { return .unknown }
        let peOffset = UInt64(dos[60]) | UInt64(dos[61]) << 8 | UInt64(dos[62]) << 16 | UInt64(dos[63]) << 24
        guard (try? h.seek(toOffset: peOffset)) != nil, let pe = try? h.read(upToCount: 6), pe.count == 6,
              pe[0] == 0x50, pe[1] == 0x45 else { return .unknown }
        switch UInt16(pe[4]) | UInt16(pe[5]) << 8 {
        case 0x8664: return .x64
        case 0x014C: return .x86
        default: return .unknown
        }
    }
}
