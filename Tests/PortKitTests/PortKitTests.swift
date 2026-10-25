import Foundation
import Testing
@testable import PortKit

@Suite struct SteamCMDParsing {
    @Test func loginSucceeds() {
        let out = """
        Logging in user 'gamer' [U:1:12345] to Steam Public...OK
        Waiting for client config...OK
        Waiting for user info...OK
        """
        #expect(SteamCMD.classifyLogin(out) == .ok)
    }

    @Test func loginNeedsGuard() {
        #expect(SteamCMD.classifyLogin("Logging in user 'g' to Steam Public...\nThis account is protected by a Steam Guard mobile authenticator.\nTwo-factor code:") == .needsGuardCode)
        #expect(SteamCMD.classifyLogin("Logging in user 'g' to Steam Public...FAILED (Account Logon Denied)") == .needsGuardCode)
    }

    @Test func loginWrongPassword() {
        #expect(SteamCMD.classifyLogin("Logging in user 'g' to Steam Public...FAILED (Invalid Password)") == .failed("Wrong username or password."))
    }

    @Test func downloadOutcomes() {
        #expect(SteamCMD.classifyDownload("Success! App '220' fully installed.", appID: 220) == .success)
        #expect(SteamCMD.classifyDownload("Success! App '220' already up to date.", appID: 220) == .success)
        #expect(SteamCMD.classifyDownload("ERROR! Failed to install app '220' (No subscription)", appID: 220) == .notOwned)
        #expect(SteamCMD.classifyDownload("ERROR! Failed to install app '220' (Not enough disk space)", appID: 220) == .diskFull)
        #expect(SteamCMD.classifyDownload("Cached credentials not found.", appID: 220) == .notSignedIn)
        if case .retryable = SteamCMD.classifyDownload("Error! App '220' state is 0x602 after update job.", appID: 220) {} else {
            Issue.record("0x602 should be retryable")
        }
    }

    @Test func progress() {
        #expect(SteamCMD.parseProgress(" Update state (0x61) downloading, progress: 42.50 (100 / 200)") == 0.425)
        #expect(SteamCMD.parseProgress("Loading Steam API...OK") == nil)
    }
}

@Suite struct TextHandling {
    @Test func promptsFlushWithoutNewline() {
        let got = ProcessRunner.Collected()
        let buffer = LineBuffer { got.append($0) }
        buffer.feed("line one\nTwo-factor code:")
        #expect(got.text == "line one\nTwo-factor code:")
    }

    @Test func carriageReturnsSplitLines() {
        let got = ProcessRunner.Collected()
        let buffer = LineBuffer { got.append($0) }
        buffer.feed("a\rb\r\nc")
        buffer.flush()
        #expect(got.text == "a\nb\nc")
    }

    @Test func argumentWords() {
        #expect("-windowed  -dx11".argumentWords == ["-windowed", "-dx11"])
        #expect(#"-name "Big Boss" -x 'a b'"#.argumentWords == ["-name", "Big Boss", "-x", "a b"])
        #expect("".argumentWords == [])
    }

    @Test func shellQuoting() {
        #expect("it's".shellQuoted == #"'it'\''s'"#)
    }

    @Test func fileSafe() {
        #expect("Half-Life 2: Episode One".fileSafe == "Half-Life 2 Episode One")
        #expect("///".fileSafe == "Game")
    }
}

@Suite struct SteamWindows {
    func page(_ id: String, _ title: String, _ url: String = "about:blank?createflags=2") -> SteamUI.Page {
        SteamUI.Page(id: id, title: title, type: "page", url: url, webSocketDebuggerUrl: nil)
    }

    @Test func hidesHelperPages() {
        let all = [page("1", "Steam"), page("2", "Account Menu"), page("3", "Store Supernav"),
                   page("4", "Welcome to Steam", "https://store.steampowered.com/"), page("5", "SharedJSContext", "https://steamloopback.host/"),
                   page("6", "Friends List")]
        #expect(SteamUI.visiblePages(all).map(\.title) == ["Steam", "Friends List"])
    }

    @Test func prefersSignInThenNewDialogThenMain() {
        let main = page("1", "Steam"), friends = page("2", "Friends List"), dialog = page("3", "Install - Game")
        #expect(SteamUI.preferred([friends, main], newIDs: []) == main)
        #expect(SteamUI.preferred([friends, main, dialog], newIDs: ["3"]) == dialog)
        #expect(SteamUI.preferred([main, page("4", "Sign in to Steam")], newIDs: []).map(\.id) == "4")
    }
}

@Suite struct Porting {
    func makeGame(_ files: [String: Int]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portkit-test-\(UUID().uuidString)")
        for (path, size) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: size).write(to: url)
        }
        return dir
    }

    @Test func picksMainExe() throws {
        let dir = try makeGame([
            "Hollow Knight.exe": 600_000,
            "UnityCrashHandler64.exe": 1_500_000,
            "_CommonRedist/vcredist_x64.exe": 9_000_000,
            "unins000.exe": 2_000_000,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let exes = Porter.candidateExes(in: dir, gameName: "Hollow Knight")
        #expect(exes.first?.lastPathComponent == "Hollow Knight.exe")
        #expect(!exes.contains { $0.lastPathComponent.hasPrefix("unins") })
    }

    @Test func prefersUnrealShippingBinary() throws {
        let dir = try makeGame([
            "Stray.exe": 300_000,
            "Hk_project/Binaries/Win64/Stray-Win64-Shipping.exe": 90_000_000,
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(Porter.candidateExes(in: dir, gameName: "Stray").first?.lastPathComponent == "Stray-Win64-Shipping.exe")
    }

    @Test func detectsSteamworksAndAntiCheat() throws {
        let dir = try makeGame(["game.exe": 10, "steam_api64.dll": 10, "EasyAntiCheat/EasyAntiCheat_Setup.exe": 10])
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Porter.analyze(dir)
        #expect(a.usesSteamworks)
        #expect(a.antiCheat == "Easy Anti-Cheat")
    }

    @Test func peArch() throws {
        func pe(machine: UInt16) -> Data {
            var d = Data(count: 0x100)
            d[0] = 0x4D; d[1] = 0x5A; d[60] = 0x80
            d[0x80] = 0x50; d[0x81] = 0x45
            d[0x84] = UInt8(machine & 0xFF); d[0x85] = UInt8(machine >> 8)
            return d
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("portkit-pe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let x64 = dir.appendingPathComponent("a.exe"), x86 = dir.appendingPathComponent("b.exe"), bad = dir.appendingPathComponent("c.exe")
        try pe(machine: 0x8664).write(to: x64)
        try pe(machine: 0x014C).write(to: x86)
        try Data("nope".utf8).write(to: bad)
        #expect(PEArch.of(x64) == .x64)
        #expect(PEArch.of(x86) == .x86)
        #expect(PEArch.of(bad) == .unknown)
    }

    @Test func launchScriptQuotesEverything() {
        var game = PortedGame(appID: 1, name: "Bob's \"Game\"", installDir: "/tmp/x", exePath: "/tmp/it's here/game.exe",
                              appPath: "", headerImage: nil)
        game.launchArgs = "-windowed '-name=a b'"
        game.graphics = .dxvk
        let script = Porter.launchScript(for: game, wine: URL(fileURLWithPath: "/w/bin/wine"))
        #expect(script.contains(#"EXE='/tmp/it'\''s here/game.exe'"#))
        #expect(script.contains(#"'-windowed' '-name=a b'"#))
        #expect(script.contains("WINEDLLOVERRIDES"))
    }

    @Test func libraryDecodesOldFormat() throws {
        let json = #"[{"appID":5,"name":"Old","installDir":"/a","exePath":"/a/b.exe","appPath":"/c.app"}]"#
        let games = try JSONDecoder().decode([PortedGame].self, from: Data(json.utf8))
        #expect(games.first?.graphics == .wined3d)
        #expect(games.first?.launchSteamFirst == true)
    }

    @Test func steamDRMGamesLaunchThroughSteam() {
        var game = PortedGame(appID: 200260, name: "Batman: Arkham City", installDir: "/g", exePath: "/g/BatmanAC.exe",
                              appPath: "", headerImage: nil)
        game.launchThroughSteam = true
        let script = Porter.launchScript(for: game, wine: URL(fileURLWithPath: "/w/bin/wine"))
        #expect(script.contains("-applaunch 200260"))
        #expect(script.contains("loginusers.vdf"))
        #expect(script.contains("-cef-disable-gpu"))
    }

    @Test func steamworksGamesDefaultToSteamLaunch() throws {
        let json = #"[{"appID":5,"name":"Old","installDir":"/a","exePath":"/a/b.exe","appPath":"/c.app","usesSteamworks":true}]"#
        let games = try JSONDecoder().decode([PortedGame].self, from: Data(json.utf8))
        #expect(games.first?.launchThroughSteam == true)
    }

    @Test func readsAppManifest() {
        let acf = """
        "AppState"
        {
        	"appid"		"200260"
        	"installdir"		"Batman Arkham City GOTY"
        }
        """
        #expect(Wine.vdfValue("installdir", in: acf) == "Batman Arkham City GOTY")
        #expect(Wine.vdfValue("missing", in: acf) == nil)
    }

    @Test func icnsHeader() {
        let data = Porter.icnsData(png: Data([1, 2, 3]))
        #expect(data.prefix(4) == Data("icns".utf8))
        #expect(data.count == 8 + 8 + 3)
    }
}
