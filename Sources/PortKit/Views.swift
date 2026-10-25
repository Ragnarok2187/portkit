import AppKit
import SwiftUI

@main
struct PortKitApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Also lets `swift run` (no .app bundle) get a Dock icon and focus.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("PortKit") {
            RootView().environmentObject(model).frame(minWidth: 920, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("PortKit on GitHub") { NSWorkspace.shared.open(Links.repo) }
                Button("Report a Problem…") { NSWorkspace.shared.open(Links.issues) }
                Divider()
                Button("Open Logs Folder") {
                    Paths.ensure(Paths.logs)
                    NSWorkspace.shared.open(Paths.logs)
                }
            }
        }
    }
}

enum Links {
    static let repo = URL(string: "https://github.com/\(Bundle.main.object(forInfoDictionaryKey: "PKRepository") as? String ?? "Ragnarok2187/portkit")")!
    static var issues: URL { repo.appendingPathComponent("issues") }
}

enum Pane: String, CaseIterable, Identifiable {
    case setup = "Setup", store = "Get Games", library = "Library", steam = "Steam", activity = "Activity"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: "gearshape"
        case .store: "magnifyingglass"
        case .library: "gamecontroller"
        case .steam: "macwindow"
        case .activity: "terminal"
        }
    }
}

/// View-local state holder. Used instead of @State because the Command Line Tools
/// toolchain lacks the SwiftUI macro plugin that @State expands through.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $model.pane) { p in
                Label(p.rawValue, systemImage: p.icon).tag(p)
            }
            .navigationSplitViewColumnWidth(180)
        } detail: {
            VStack(spacing: 0) {
                switch model.pane ?? .setup {
                case .setup: SetupView()
                case .store: StoreView()
                case .library: LibraryView()
                case .steam: SteamWindowView()
                case .activity: ActivityView()
                }
                if let busy = model.busy { StatusBar(title: busy) }
            }
        }
        .onAppear { if model.ready { model.pane = model.library.isEmpty ? .store : .library } }
        // Picks up sign-ins done in the Windows Steam window while PortKit was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.busy == nil { model.refresh() }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("Show Activity") { model.errorMessage = nil; model.pane = .activity }
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("Heads up", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var body: some View {
        HStack {
            if let p = model.progress {
                ProgressView(value: p).frame(width: 200)
                Text("\(Int(p * 100))%").monospacedDigit()
            } else {
                ProgressView().controlSize(.small)
            }
            Text(title).lineLimit(1)
            Spacer()
            if let last = model.log.last { Text(last).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Button("Cancel") { model.cancel() }
        }
        .padding(10)
        .background(.bar)
    }
}

// MARK: - Setup

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var password = Box("")
    @StateObject private var guardCode = Box("")

    private var toolsReady: Bool { model.steamcmdInstalled && model.wine != nil && model.prefixReady && model.dxvkInstalled }

    var body: some View {
        Form {
            Section {
                Text("PortKit downloads the Windows version of games you own on Steam and wraps each one in a Mac app that runs it through Wine, which translates Windows calls to macOS while the game runs.")
                    .foregroundStyle(.secondary)
            }

            Section {
                StepRow(done: model.rosetta, title: "Rosetta 2",
                        detail: model.rosetta ? "Available" : "Required on Apple Silicon. Install it, then reopen PortKit.") {
                    if !model.rosetta {
                        Button("Install…") { installRosetta() }
                    }
                }
                StepRow(done: model.steamcmdInstalled, title: "SteamCMD", detail: "Valve's official command-line Steam client") {
                    Button(model.steamcmdInstalled ? "Reinstall" : "Install") { model.installSteamCMD() }
                }
                StepRow(done: model.wine != nil, title: "Wine", detail: model.wine?.path ?? "Not installed") {
                    HStack {
                        Button(model.wine == nil ? "Install" : "Update") { model.installWine() }
                        Button("Choose…") { chooseWine() }
                    }
                }
                StepRow(done: model.dxvkInstalled, title: "DXVK", detail: "Faster DirectX 10–11 through Vulkan and Metal (MoltenVK)") {
                    Button(model.dxvkInstalled ? "Reinstall" : "Install") { model.installDXVK() }
                }
                StepRow(done: model.prefixReady, title: "Windows prefix", detail: "A virtual C: drive shared by all ported games") {
                    HStack {
                        Button(model.prefixReady ? "Recreate" : "Create") { model.createPrefix() }.disabled(model.wine == nil)
                        Button("winecfg") { model.openWinecfg() }.disabled(!model.prefixReady)
                    }
                }
            } header: {
                HStack {
                    Text("1. Tools")
                    Spacer()
                    if !toolsReady {
                        Button("Install Everything") { model.installAll() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.rosetta)
                    }
                }
            }
            .disabled(model.busy != nil)

            Section("2. Steam account") {
                if let user = model.signedInUser {
                    HStack {
                        Label("Signed in as \(user)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Sign out") { model.signOut() }
                    }
                } else {
                    TextField("Steam username", text: $model.username)
                    SecureField("Password", text: $password.value)
                    if model.needsGuardCode {
                        TextField("Steam Guard code", text: $guardCode.value)
                    }
                    HStack {
                        Text("Your password goes straight to Valve's SteamCMD and is never saved. If you use the Steam Mobile app, approve the sign-in there.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Sign in") {
                            model.signIn(password: password.value, guardCode: guardCode.value)
                            password.value = ""; guardCode.value = ""
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.steamcmdInstalled || model.username.isEmpty || password.value.isEmpty || model.busy != nil)
                    }
                }
            }

            Section("3. Steam for Windows") {
                StepRow(done: model.windowsSteamInstalled && model.windowsSteamSignedIn, title: "Steam for Windows (in prefix)",
                        detail: !model.windowsSteamInstalled
                            ? "Needed by games with Steam copy protection, achievements or multiplayer. Installed automatically when a game needs it."
                            : model.windowsSteamSignedIn ? "Installed and signed in"
                            : "Installed but not signed in. Click Sign In.") {
                    HStack {
                        Button("Install") { model.installWindowsSteam() }.disabled(!model.prefixReady || model.busy != nil)
                        Button(model.windowsSteamSignedIn ? "Open" : "Sign In") { model.openWindowsSteam() }
                            .disabled(!model.windowsSteamInstalled)
                    }
                }
            }

            Section("Display") {
                Toggle("Retina mode (sharper, but heavier on the GPU)", isOn: Binding(
                    get: { model.retinaMode }, set: { model.setRetina($0) }))
                    .disabled(model.busy != nil)
            }

            Section("Locations") {
                LabeledContent("Game files", value: Paths.gamesRoot.path)
                LabeledContent("Mac apps", value: Paths.appsOut.path)
                HStack {
                    Button("Change game folder…") { chooseGamesRoot() }
                    Button("Show apps in Finder") {
                        Paths.ensure(Paths.appsOut)
                        NSWorkspace.shared.open(Paths.appsOut)
                    }
                    Button("Rebuild all game apps") { model.rebuildAll() }.disabled(model.library.isEmpty || model.busy != nil)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
    }

    private func installRosetta() {
        // Opens Terminal so the user sees and approves the system install themselves.
        let script = "tell application \"Terminal\" to do script \"softwareupdate --install-rosetta --agree-to-license\""
        NSAppleScript(source: script)?.executeAndReturnError(nil)
    }

    private func chooseWine() {
        let panel = NSOpenPanel()
        panel.message = "Choose a wine or wine64 binary (e.g. from Game Porting Toolkit, Whisky or a Wine.app)"
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK { model.setCustomWine(panel.url) }
    }

    private func chooseGamesRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            UserDefaults.standard.set(url.path, forKey: "gamesRoot")
            model.refresh()
        }
    }
}

struct StepRow<Actions: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
            actions()
        }
    }
}

// MARK: - Store

struct StoreView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var query = Box("")
    @StateObject private var windowsOnly = Box(true)

    var results: [StoreItem] {
        windowsOnly.value ? model.searchResults.filter(\.isWindowsOnly) : model.searchResults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                TextField("Search the Steam store, or enter an App ID", text: $query.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search(query.value) }
                if model.searching { ProgressView().controlSize(.small) }
                Button("Search") { model.search(query.value) }
                Toggle("Windows-only", isOn: $windowsOnly.value)
            }
            .padding()
            if !model.ready {
                Label("Finish the Setup page before installing games.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).padding(.horizontal).padding(.bottom, 8)
            }
            List(results) { item in
                HStack {
                    Thumbnail(url: item.tiny_image, width: 120, height: 45)
                    VStack(alignment: .leading) {
                        Text(item.name).font(.headline)
                        HStack(spacing: 6) {
                            Text("App \(String(item.id))")
                            if item.platforms?.windows == true { Tag("Windows") }
                            if item.platforms?.mac == true { Tag("Mac") }
                            if item.platforms?.linux == true { Tag("Linux") }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.library.contains(where: { $0.appID == item.id }) {
                        Text("In library").foregroundStyle(.secondary)
                    }
                    Button("Install & Port") { model.installAndPort(item.id) }
                        .disabled(!model.ready || model.busy != nil)
                }
                .padding(.vertical, 4)
            }
            .overlay {
                if results.isEmpty {
                    if model.searchResults.isEmpty {
                        ContentUnavailableView("Find a game", systemImage: "magnifyingglass",
                                               description: Text("Only games your Steam account owns can be downloaded."))
                    } else {
                        ContentUnavailableView("No Windows-only matches", systemImage: "line.3.horizontal.decrease.circle",
                                               description: Text("Turn off “Windows-only” to see every result."))
                    }
                }
            }
        }
    }
}

struct Thumbnail: View {
    let url: String?
    let width: CGFloat
    let height: CGFloat
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { img in
            img.resizable().aspectRatio(contentMode: .fit)
        } placeholder: { Color.secondary.opacity(0.15) }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary
    init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }
    var body: some View {
        Text(text).padding(.horizontal, 5).padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
    }
}

// MARK: - Library

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var pendingDelete = Box<PortedGame?>(nil)
    @StateObject private var editing = Box<PortedGame?>(nil)

    var body: some View {
        List(model.library) { game in
            HStack {
                Thumbnail(url: game.headerImage, width: 140, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name).font(.headline)
                    HStack(spacing: 6) {
                        Text(game.launchThroughSteam ? "Launches through Steam" : URL(fileURLWithPath: game.exePath).lastPathComponent)
                        if game.graphics == .dxvk { Tag("DXVK", color: .blue) }
                        if game.usesSteamworks { Tag("Steamworks", color: .purple) }
                        if let ac = game.antiCheat { Tag(ac, color: .red).help("Kernel anti-cheat usually blocks Wine.") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Play") { model.launch(game) }.buttonStyle(.borderedProminent)
                Button { editing.value = game } label: { Image(systemName: "slider.horizontal.3") }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                    .disabled(model.busy != nil)
                Menu {
                    Button("Settings…") { editing.value = game }
                    Button("Check for Updates") { model.updateGame(game, validate: false) }
                    Button("Verify Files") { model.updateGame(game, validate: true) }
                    Divider()
                    Button("Show in Finder") { model.reveal(game) }
                    Button("Open Log") { model.openLog(game) }
                    Divider()
                    Button("Uninstall…", role: .destructive) { pendingDelete.value = game }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.busy != nil)
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if model.library.isEmpty {
                ContentUnavailableView("No ported games yet", systemImage: "gamecontroller",
                                       description: Text("Use Get Games to download and port a Windows game you own."))
            }
        }
        .sheet(item: $editing.value) { game in
            GameSettingsView(game: game, choices: model.choices(for: game)) { updated in
                model.save(updated)
            }
        }
        .confirmationDialog("Uninstall \(pendingDelete.value?.name ?? "")?", isPresented: Binding(
            get: { pendingDelete.value != nil }, set: { if !$0 { pendingDelete.value = nil } })) {
            Button("Delete game files and Mac app", role: .destructive) {
                if let g = pendingDelete.value { model.uninstall(g) }
            }
        } message: {
            Text("This permanently deletes the downloaded files. You can download the game again later.")
        }
    }
}

struct GameSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft: Box<PortedGame>
    let choices: [URL]
    let onSave: (PortedGame) -> Void

    init(game: PortedGame, choices: [URL], onSave: @escaping (PortedGame) -> Void) {
        _draft = StateObject(wrappedValue: Box(game))
        self.choices = choices
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(draft.value.name).font(.title2).bold().padding([.top, .horizontal])
            Form {
                Picker("Executable", selection: $draft.value.exePath) {
                    ForEach(choices, id: \.path) { exe in
                        Text(exe.path.replacingOccurrences(of: draft.value.installDir + "/", with: "")).tag(exe.path)
                    }
                    if !choices.contains(where: { $0.path == draft.value.exePath }) {
                        Text(URL(fileURLWithPath: draft.value.exePath).lastPathComponent).tag(draft.value.exePath)
                    }
                }
                TextField("Launch options", text: $draft.value.launchArgs, prompt: Text("e.g. -windowed -dx11"))
                Picker("Graphics", selection: $draft.value.graphics) {
                    ForEach(Graphics.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Launch through Steam (needed for Steam copy protection)", isOn: $draft.value.launchThroughSteam)
                if !draft.value.launchThroughSteam {
                    Toggle("Start Windows Steam before the game", isOn: $draft.value.launchSteamFirst)
                }
                if draft.value.graphics == .dxvk && !Wine.dxvkInstalled {
                    Label("Install DXVK on the Setup page first.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { onSave(draft.value); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560)
    }
}

// MARK: - Steam windows

struct SteamWindowView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = SteamUI()
    @StateObject private var text = Box("")
    @StateObject private var secret = Box("")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Window", selection: Binding(get: { ui.selected }, set: { if let p = $0 { ui.select(p) } })) {
                    ForEach(ui.pages) { Text($0.title).tag(Optional($0)) }
                }
                .frame(maxWidth: 360)
                Spacer()
                if model.windowsSteamSignedIn {
                    Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Text("This is Steam for Windows, shown through PortKit. Click and type here to use it. Sign in by scanning the QR code with the Steam Mobile app, or with your account name and password below.")
                .font(.callout).foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                if let image = ui.image {
                    RemotePageImage(image: image, onClick: ui.click, onScroll: ui.scroll)
                        .padding(4)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text(ui.status.isEmpty ? "Loading…" : ui.status).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minHeight: 300)

            HStack {
                TextField("Type into the selected field in Steam", text: $text.value)
                    .onSubmit { ui.type(text.value); text.value = "" }
                Button("Type") { ui.type(text.value); text.value = "" }.disabled(text.value.isEmpty)
                SecureField("Password (typed into Steam, never saved)", text: $secret.value)
                    .onSubmit { ui.type(secret.value); secret.value = "" }
                Button("Type Password") { ui.type(secret.value); secret.value = "" }.disabled(secret.value.isEmpty)
            }
            HStack {
                Button("Tab") { ui.press(.tab) }
                Button("Delete") { ui.press(.backspace) }
                Button("Enter") { ui.press(.enter) }
                Button("Esc") { ui.press(.escape) }
                Spacer()
                Text("Click a field in the picture first, then type.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            if let wine = model.wine, model.windowsSteamInstalled { try? Wine.startWindowsSteam(wine) }
            ui.start()
        }
        .onDisappear { ui.stop(); model.refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            let was = model.windowsSteamSignedIn
            model.windowsSteamSignedIn = Wine.windowsSteamSignedIn
            if !was && model.windowsSteamSignedIn {
                model.notice = "Steam for Windows is signed in. You can play your games now."
            }
        }
        .overlay {
            if !model.windowsSteamInstalled {
                ContentUnavailableView("Steam for Windows isn't installed", systemImage: "macwindow",
                                       description: Text("Install it on the Setup page. PortKit also installs it automatically when a game needs it."))
                    .background(.background)
            }
        }
    }
}

/// Draws a captured Steam page and maps clicks back to the page's own pixel coordinates.
struct RemotePageImage: View {
    let image: NSImage
    let onClick: (CGPoint) -> Void
    let onScroll: (CGPoint, CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let size = image.size
            let scale = min(geo.size.width / max(size.width, 1), geo.size.height / max(size.height, 1), 1)
            let shown = CGSize(width: size.width * scale, height: size.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            Image(nsImage: image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { p in
                    let x = (p.x - origin.x) / scale, y = (p.y - origin.y) / scale
                    if x >= 0, y >= 0, x <= size.width, y <= size.height { onClick(CGPoint(x: x, y: y)) }
                }
        }
    }
}

// MARK: - Activity

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Copy Log") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.log.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") { model.log.removeAll() }
            }
            .padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled).id(i)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
        }
    }
}
