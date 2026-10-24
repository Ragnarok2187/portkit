import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    // Setup state
    @Published var steamcmdInstalled = SteamCMD.isInstalled
    @Published var wine: URL? = Wine.locate()
    @Published var rosetta = true
    @Published var prefixReady = Wine.prefixReady
    @Published var windowsSteamInstalled = FileManager.default.fileExists(atPath: Paths.windowsSteamExe.path)
    @Published var dxvkInstalled = Wine.dxvkInstalled
    @Published var retinaMode = UserDefaults.standard.bool(forKey: "retinaMode")

    // Steam account (password is never stored; SteamCMD caches its own login token)
    @Published var username = UserDefaults.standard.string(forKey: "steamUser") ?? ""
    @Published var signedInUser = UserDefaults.standard.string(forKey: "signedInUser")
    @Published var needsGuardCode = false

    // Activity
    @Published var busy: String?
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var errorMessage: String?
    @Published var notice: String?

    @Published var searchResults: [StoreItem] = []
    @Published var searching = false
    @Published var library: [PortedGame] = Library.load()

    private var exeCache: [Int: [URL]] = [:]
    private var current: RunningProcess?
    private var cancelled = false

    var ready: Bool { steamcmdInstalled && wine != nil && prefixReady && signedInUser != nil && rosetta }

    init() {
        Task { rosetta = await Wine.rosettaAvailable() }
    }

    func append(_ line: String) {
        log.append(line)
        if log.count > 5000 { log.removeFirst(log.count - 5000) }
    }

    private nonisolated func logger() -> @Sendable (String) -> Void {
        { [weak self] line in Task { @MainActor in self?.append(line) } }
    }

    private nonisolated func tracker() -> @Sendable (RunningProcess) -> Void {
        { [weak self] p in Task { @MainActor in self?.current = p } }
    }

    private func perform(_ title: String, _ work: @escaping () async throws -> Void) {
        guard busy == nil else { return }
        busy = title
        progress = nil
        cancelled = false
        append("▶︎ \(title)")
        Task {
            do { try await work() } catch {
                if cancelled {
                    append("Cancelled.")
                } else {
                    errorMessage = error.localizedDescription
                    append("✖︎ \(error.localizedDescription)")
                }
            }
            busy = nil
            progress = nil
            current = nil
            refresh()
        }
    }

    func refresh() {
        steamcmdInstalled = SteamCMD.isInstalled
        wine = Wine.locate()
        prefixReady = Wine.prefixReady
        windowsSteamInstalled = FileManager.default.fileExists(atPath: Paths.windowsSteamExe.path)
        dxvkInstalled = Wine.dxvkInstalled
    }

    func cancel() {
        cancelled = true
        current?.cancel()
    }

    // MARK: Setup

    func installSteamCMD() { perform("Installing SteamCMD") { try await SteamCMD.install(log: self.logger()) } }
    func installWine() { perform("Installing Wine") { try await Wine.install(log: self.logger()) } }
    func installDXVK() { perform("Installing DXVK") { try await Wine.installDXVK(log: self.logger()) } }

    /// One click for everything that doesn't need the user's input.
    func installAll() {
        perform("Setting up PortKit") {
            if !SteamCMD.isInstalled { try await SteamCMD.install(log: self.logger()) }
            if Wine.locate() == nil { try await Wine.install(log: self.logger()) }
            if !Wine.dxvkInstalled { try await Wine.installDXVK(log: self.logger()) }
            guard let wine = Wine.locate() else { throw PortKitError("Wine is not installed.") }
            if !Wine.prefixReady { try await Wine.initPrefix(wine, log: self.logger()) }
            self.append("✔︎ Tools ready. Sign in to Steam next.")
        }
    }

    func createPrefix() {
        guard let wine else { return }
        perform("Creating Windows prefix") {
            try? FileManager.default.removeItem(at: Paths.prefix)
            try await Wine.initPrefix(wine, log: self.logger())
        }
    }

    func setRetina(_ on: Bool) {
        retinaMode = on
        UserDefaults.standard.set(on, forKey: "retinaMode")
        guard let wine, prefixReady else { return }
        perform(on ? "Enabling Retina mode" : "Disabling Retina mode") {
            await Wine.setRetina(wine, enabled: on, log: self.logger())
        }
    }

    func installWindowsSteam() {
        guard let wine else { return }
        perform("Installing Windows Steam") { try await Wine.installWindowsSteam(wine, log: self.logger()) }
    }

    func openWindowsSteam() {
        guard let wine else { return }
        let exe = Paths.windowsSteamExe
        Task.detached { await Wine.run(wine, [exe.path], log: { _ in }) }
    }

    func openWinecfg() {
        guard let wine else { return }
        Task.detached { await Wine.run(wine, ["winecfg"], log: { _ in }) }
    }

    func setCustomWine(_ url: URL?) {
        UserDefaults.standard.set(url?.path, forKey: "customWine")
        refresh()
        if url != nil, wine?.path != url?.path {
            errorMessage = "That file isn't an executable wine binary."
            UserDefaults.standard.removeObject(forKey: "customWine")
            refresh()
        }
    }

    func signIn(password: String, guardCode: String) {
        let user = username.trimmingCharacters(in: .whitespaces)
        guard !user.isEmpty, !password.isEmpty else { return }
        UserDefaults.standard.set(user, forKey: "steamUser")
        perform("Signing in to Steam") {
            self.append("If you use the Steam Mobile app, approve the sign-in on your phone now.")
            let result = await SteamCMD.login(user: user, password: password,
                                              guardCode: guardCode.isEmpty ? nil : guardCode,
                                              started: self.tracker(), log: self.logger())
            switch result {
            case .ok:
                self.signedInUser = user
                self.needsGuardCode = false
                UserDefaults.standard.set(user, forKey: "signedInUser")
                self.append("✔︎ Signed in as \(user)")
            case .needsGuardCode:
                self.needsGuardCode = true
                self.notice = "Steam sent a Steam Guard code to your email or authenticator app. Enter it and sign in again."
            case .failed(let reason):
                throw PortKitError(reason)
            }
        }
    }

    func signOut() {
        signedInUser = nil
        UserDefaults.standard.removeObject(forKey: "signedInUser")
    }

    // MARK: Store

    func search(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        searching = true
        Task {
            defer { searching = false }
            do {
                if let id = Int(t) {
                    let d = try await SteamStore.details(id)
                    searchResults = [StoreItem(id: id, name: d.name, tiny_image: d.header_image, platforms: d.platforms)]
                } else {
                    searchResults = try await SteamStore.search(t)
                }
            } catch {
                errorMessage = "Store search failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: Download + port

    func installAndPort(_ appID: Int) {
        guard let user = signedInUser, let wine else { return }
        perform("Installing app \(appID)") {
            let details = try await SteamStore.details(appID)
            if details.platforms?.mac == true {
                self.append("Note: \(details.name) has a native macOS version — the Mac Steam client will run it better.")
            }
            if details.platforms?.windows == false {
                throw PortKitError("\(details.name) has no Windows version to download.")
            }
            let dir = Paths.gamesRoot.appendingPathComponent("\(appID)", isDirectory: true)
            if let free = Paths.freeSpace(at: dir), free < 2_000_000_000 {
                self.append("Warning: only \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free on this disk.")
            }
            self.busy = "Downloading \(details.name)"
            try await SteamCMD.downloadWindowsApp(
                appID: appID, user: user, into: dir, validate: true,
                started: self.tracker(),
                progress: { v in Task { @MainActor in self.progress = v } },
                log: self.logger())

            self.busy = "Porting \(details.name)"
            self.progress = nil
            let exes = Porter.candidateExes(in: dir, gameName: details.name)
            guard let best = exes.first else { throw PortKitError("No Windows executable found in \(dir.path).") }
            self.exeCache[appID] = exes
            var game = self.library.first(where: { $0.appID == appID })
                ?? PortedGame(appID: appID, name: details.name, installDir: dir.path, exePath: best.path,
                              appPath: "", headerImage: details.header_image)
            if !FileManager.default.fileExists(atPath: game.exePath) { game.exePath = best.path }
            let analysis = Porter.analyze(dir)
            game.usesSteamworks = analysis.usesSteamworks
            game.antiCheat = analysis.antiCheat
            game.appPath = try await Porter.buildApp(for: game, wine: wine).path
            self.store(game)
            self.append("✔︎ Created \(game.appPath) → \(URL(fileURLWithPath: game.exePath).lastPathComponent)")
            if let ac = analysis.antiCheat {
                self.notice = "\(details.name) uses \(ac). Kernel-level anti-cheat doesn't run under Wine, so online play (and sometimes the whole game) will likely fail."
            } else if analysis.usesSteamworks && !self.windowsSteamInstalled {
                self.notice = "\(details.name) uses Steamworks. If it won't start, install the Windows Steam client on the Setup page and sign in to it once."
            }
        }
    }

    func updateGame(_ game: PortedGame, validate: Bool) {
        guard let user = signedInUser else { errorMessage = "Sign in to Steam on the Setup page first."; return }
        perform(validate ? "Verifying \(game.name)" : "Updating \(game.name)") {
            try await SteamCMD.downloadWindowsApp(
                appID: game.appID, user: user, into: URL(fileURLWithPath: game.installDir), validate: validate,
                started: self.tracker(),
                progress: { v in Task { @MainActor in self.progress = v } },
                log: self.logger())
            self.exeCache[game.appID] = nil
            if let wine = self.wine {
                var g = game
                g.appPath = try await Porter.buildApp(for: g, wine: wine).path
                self.store(g)
            }
            self.append("✔︎ \(game.name) is up to date.")
        }
    }

    func choices(for game: PortedGame) -> [URL] {
        if let c = exeCache[game.appID] { return c }
        let c = Porter.candidateExes(in: URL(fileURLWithPath: game.installDir), gameName: game.name)
        exeCache[game.appID] = c
        return c
    }

    func save(_ game: PortedGame) {
        guard let wine else { errorMessage = "Install Wine on the Setup page first."; return }
        perform("Rebuilding \(game.name)") {
            var g = game
            g.appPath = try await Porter.buildApp(for: g, wine: wine).path
            self.store(g)
        }
    }

    /// Regenerates every game's launcher, e.g. after switching Wine builds.
    func rebuildAll() {
        guard let wine else { return }
        perform("Rebuilding all games") {
            for game in self.library {
                var g = game
                g.appPath = try await Porter.buildApp(for: g, wine: wine).path
                self.store(g)
            }
        }
    }

    private func store(_ game: PortedGame) {
        library.removeAll { $0.appID == game.appID }
        library.append(game)
        library.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Library.save(library)
    }

    func launch(_ game: PortedGame) {
        let url = URL(fileURLWithPath: game.appPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            save(game)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
        }
    }

    func reveal(_ game: PortedGame) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.appPath)])
    }

    func openLog(_ game: PortedGame) {
        let log = Paths.logs.appendingPathComponent("\(game.appID).log")
        if FileManager.default.fileExists(atPath: log.path) {
            NSWorkspace.shared.open(log)
        } else {
            notice = "No log yet — launch the game first."
        }
    }

    func uninstall(_ game: PortedGame) {
        try? FileManager.default.removeItem(atPath: game.appPath)
        try? FileManager.default.removeItem(atPath: game.installDir)
        library.removeAll { $0.appID == game.appID }
        Library.save(library)
    }
}
