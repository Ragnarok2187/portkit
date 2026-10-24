import AppKit
import Foundation

enum Graphics: String, Codable, CaseIterable, Identifiable {
    case wined3d, dxvk
    var id: String { rawValue }
    var label: String {
        switch self {
        case .wined3d: "OpenGL (WineD3D, most compatible)"
        case .dxvk: "Vulkan/Metal (DXVK, faster for DirectX 10–11)"
        }
    }
}

struct PortedGame: Codable, Identifiable, Hashable {
    var id: Int { appID }
    let appID: Int
    var name: String
    var installDir: String
    var exePath: String
    var appPath: String
    var headerImage: String?
    var launchSteamFirst = true
    var launchArgs = ""
    var graphics = Graphics.wined3d
    var usesSteamworks = false
    var antiCheat: String?

    init(appID: Int, name: String, installDir: String, exePath: String, appPath: String, headerImage: String?) {
        self.appID = appID; self.name = name; self.installDir = installDir
        self.exePath = exePath; self.appPath = appPath; self.headerImage = headerImage
    }

    // Tolerates library files written by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appID = try c.decode(Int.self, forKey: .appID)
        name = try c.decode(String.self, forKey: .name)
        installDir = try c.decode(String.self, forKey: .installDir)
        exePath = try c.decode(String.self, forKey: .exePath)
        appPath = try c.decode(String.self, forKey: .appPath)
        headerImage = try c.decodeIfPresent(String.self, forKey: .headerImage)
        launchSteamFirst = try c.decodeIfPresent(Bool.self, forKey: .launchSteamFirst) ?? true
        launchArgs = try c.decodeIfPresent(String.self, forKey: .launchArgs) ?? ""
        graphics = try c.decodeIfPresent(Graphics.self, forKey: .graphics) ?? .wined3d
        usesSteamworks = try c.decodeIfPresent(Bool.self, forKey: .usesSteamworks) ?? false
        antiCheat = try c.decodeIfPresent(String.self, forKey: .antiCheat)
    }
}

/// Turns a downloaded Windows game into a double-clickable macOS .app that runs it through Wine.
enum Porter {
    private static let junk = [
        "unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx", "dotnet",
        "crashhandler", "crashreport", "crashpad", "bugsplat", "physx", "ue4prereq", "ueprereq",
        "easyanticheat", "beservice", "battleye", "cefprocess", "helper", "notification", "touchup",
        "uploader", "updater", "dxwebsetup", "oalinst", "steamerrorreporter", "reportsender",
    ]

    /// Ranks .exe files by how likely they are to be the game's main executable.
    static func candidateExes(in dir: URL, gameName: String) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        let words = gameName.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        let compactName = gameName.lowercased().filter { $0.isLetter || $0.isNumber }
        var scored: [(URL, Double)] = []
        for case let url as URL in e where url.pathExtension.lowercased() == "exe" {
            let file = url.deletingPathExtension().lastPathComponent.lowercased()
            let rel = String(url.path.dropFirst(dir.path.count)).lowercased()
            if junk.contains(where: { file.contains($0) }) || rel.contains("redist") || rel.contains("/engine/") { continue }
            let size = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var score = log10(max(size, 1))
            let compactFile = file.filter { $0.isLetter || $0.isNumber }
            if !compactName.isEmpty, !compactFile.isEmpty,
               compactFile.contains(compactName) || compactName.contains(compactFile) { score += 6 }
            score += Double(words.filter { file.contains($0) }.count) * 2
            if file.contains("shipping") { score += 3 }           // Unreal's real binary
            if rel.contains("win64") || rel.contains("x64") { score += 1 }
            if file.contains("launcher") { score -= 2 }
            score -= Double(rel.filter { $0 == "/" }.count) * 0.5 // prefer shallow paths
            scored.append((url, score))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    struct Analysis: Equatable {
        var usesSteamworks = false
        var antiCheat: String?
    }

    /// Spots things that decide whether a game can run under Wine at all.
    static func analyze(_ dir: URL) -> Analysis {
        var a = Analysis()
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return a }
        let antiCheats: [(String, String)] = [
            ("easyanticheat", "Easy Anti-Cheat"), ("battleye", "BattlEye"), ("beservice", "BattlEye"),
            ("vgk.sys", "Riot Vanguard"), ("xigncode", "XIGNCODE3"), ("nprotect", "nProtect GameGuard"),
            ("gameguard", "nProtect GameGuard"), ("faceit", "FACEIT"), ("mhyprot", "miHoYo anti-cheat"),
        ]
        for case let url as URL in e {
            let name = url.lastPathComponent.lowercased()
            if name == "steam_api.dll" || name == "steam_api64.dll" { a.usesSteamworks = true }
            if a.antiCheat == nil, let hit = antiCheats.first(where: { name.contains($0.0) }) { a.antiCheat = hit.1 }
        }
        return a
    }

    static func buildApp(for game: PortedGame, wine: URL) async throws -> URL {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: game.exePath)
        guard fm.fileExists(atPath: exe.path) else { throw PortKitError("Executable not found: \(exe.path)") }
        Paths.ensure(Paths.appsOut)
        Paths.ensure(Paths.logs)
        let app = Paths.appsOut.appendingPathComponent("\(game.name.fileSafe).app", isDirectory: true)
        // Assemble next to the destination and swap in at the end, so a failure never leaves a broken app.
        let staging = Paths.appsOut.appendingPathComponent(".\(game.appID).app.partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        let contents = staging.appendingPathComponent("Contents")
        let macos = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Lets SteamAPI_Init() identify the game when launched outside Steam's own launcher.
        try? String(game.appID).write(to: exe.deletingLastPathComponent().appendingPathComponent("steam_appid.txt"),
                                      atomically: true, encoding: .utf8)
        try applyGraphics(game)

        let hasIcon = await makeIcon(game: game, into: resources.appendingPathComponent("AppIcon.icns"))

        var plist: [String: Any] = [
            "CFBundleExecutable": "launch",
            "CFBundleIdentifier": "io.github.portkit.game\(game.appID)",
            "CFBundleName": game.name,
            "CFBundleDisplayName": game.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true,
            "LSApplicationCategoryType": "public.app-category.games",
        ]
        if hasIcon { plist["CFBundleIconFile"] = "AppIcon" }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let launcher = macos.appendingPathComponent("launch")
        try launchScript(for: game, wine: wine).write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)

        try? fm.removeItem(at: app)
        if !game.appPath.isEmpty, game.appPath != app.path { try? fm.removeItem(atPath: game.appPath) }
        try fm.moveItem(at: staging, to: app)
        return app
    }

    static func launchScript(for game: PortedGame, wine: URL) -> String {
        let args = game.launchArgs.argumentWords.map(\.shellQuoted).joined(separator: " ")
        let dxvkEnv = game.graphics == .dxvk ? """
        export WINEDLLOVERRIDES="d3d10core,d3d11=n,b"
        export DXVK_ASYNC=1
        export MVK_CONFIG_RESUME_LOST_DEVICE=1
        """ : ""
        return """
        #!/bin/bash
        # Generated by PortKit: runs the Windows build of \(game.name.replacingOccurrences(of: "\n", with: " ")) through Wine.
        export WINEPREFIX=\(Paths.prefix.path.shellQuoted)
        export WINEDEBUG=-all
        export WINEMSYNC=1
        export WINEESYNC=1
        \(dxvkEnv)
        WINE=\(wine.path.shellQuoted)
        EXE=\(game.exePath.shellQuoted)
        LOG=\(Paths.logs.appendingPathComponent("\(game.appID).log").path.shellQuoted)
        STEAM_EXE="$WINEPREFIX/drive_c/Program Files (x86)/Steam/steam.exe"
        mkdir -p "$(dirname "$LOG")"
        echo "=== launch $(date) ===" >>"$LOG"
        fail() { osascript -e "display alert \\"$1\\" message \\"$2\\"" >/dev/null 2>&1; exit 1; }
        [ -x "$WINE" ] || fail "Wine not found" "Open PortKit and reinstall Wine on the Setup page."
        [ -f "$EXE" ] || fail "Game files not found" "Open PortKit and reinstall this game."
        if [ \(game.launchSteamFirst ? "1" : "0") = 1 ] && [ -f "$STEAM_EXE" ] && ! pgrep -f 'Steam/steam.exe' >/dev/null; then
          "$WINE" "$STEAM_EXE" -silent -no-browser >>"$LOG" 2>&1 &
          # Give the Windows Steam client time to sign in before the game calls SteamAPI_Init().
          for i in $(seq 1 45); do
            pgrep -f 'steamwebhelper' >/dev/null && break
            sleep 1
          done
          sleep 5
        fi
        cd "$(dirname "$EXE")"
        "$WINE" "$EXE" \(args) "$@" >>"$LOG" 2>&1
        status=$?
        if [ $status -ne 0 ]; then
          echo "=== exited with status $status ===" >>"$LOG"
        fi
        exit $status
        """
    }

    /// DXVK DLLs sit next to the game's exe so each game picks its own renderer within the shared prefix.
    static func applyGraphics(_ game: PortedGame) throws {
        let fm = FileManager.default
        let exe = URL(fileURLWithPath: game.exePath)
        let dir = exe.deletingLastPathComponent()
        let arch = PEArch.of(exe)
        let source = Wine.dxvkFolder(for: arch == .x86 ? .x86 : .x64)
        for dll in Wine.dxvkDLLs {
            let dest = dir.appendingPathComponent(dll)
            let ours = [Wine.dxvkFolder(for: .x64), Wine.dxvkFolder(for: .x86)].compactMap { $0 }
                .contains { fm.contentsEqual(atPath: $0.appendingPathComponent(dll).path, andPath: dest.path) }
            switch game.graphics {
            case .wined3d:
                if ours { try? fm.removeItem(at: dest) }
            case .dxvk:
                guard let source else { throw PortKitError("Install DXVK on the Setup page first.") }
                let src = source.appendingPathComponent(dll)
                guard fm.fileExists(atPath: src.path) else { continue }   // macOS DXVK ships only some DLLs
                if fm.fileExists(atPath: dest.path) && !ours { continue }   // never overwrite the game's own DLL
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: src, to: dest)
            }
        }
    }

    /// Crops the store header to a centered square and writes a PNG-based .icns.
    private static func makeIcon(game: PortedGame, into icns: URL) async -> Bool {
        guard let s = game.headerImage, let url = URL(string: s),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let png = squareIconPNG(from: data) else { return false }
        return (try? icnsData(png: png).write(to: icns)) != nil
    }

    static func squareIconPNG(from imageData: Data, side out: Int = 512) -> Data? {
        guard let src = NSBitmapImageRep(data: imageData) else { return nil }
        let side = min(src.pixelsWide, src.pixelsHigh)
        let crop = NSRect(x: (src.pixelsWide - side) / 2, y: (src.pixelsHigh - side) / 2, width: side, height: side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: out, pixelsHigh: out, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: out, height: out), from: crop, operation: .copy,
                 fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// ICNS container with a single 'ic09' (512x512 PNG) element.
    static func icnsData(png: Data) -> Data {
        func be32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).bigEndian) { Data($0) } }
        return Data("icns".utf8) + be32(8 + 8 + png.count) + Data("ic09".utf8) + be32(8 + png.count) + png
    }
}

enum Library {
    static func load() -> [PortedGame] {
        guard let d = try? Data(contentsOf: Paths.libraryDB) else { return [] }
        return (try? JSONDecoder().decode([PortedGame].self, from: d)) ?? []
    }

    static func save(_ games: [PortedGame]) {
        Paths.ensure(Paths.support)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(games).write(to: Paths.libraryDB, options: .atomic)
    }
}
