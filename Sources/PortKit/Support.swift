import Foundation

enum Paths {
    static let fm = FileManager.default
    static let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PortKit", isDirectory: true)
    static let steamcmdDir = support.appendingPathComponent("steamcmd", isDirectory: true)
    static let steamcmdBinary = steamcmdDir.appendingPathComponent("steamcmd")
    static let wineDir = support.appendingPathComponent("wine", isDirectory: true)
    static let dxvkDir = support.appendingPathComponent("dxvk", isDirectory: true)
    static let prefix = support.appendingPathComponent("prefix", isDirectory: true)
    static let libraryDB = support.appendingPathComponent("library.json")
    static let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PortKit", isDirectory: true)
    /// A game's launcher touches this when it needs Steam signed in, so PortKit opens its Steam pane.
    static let showSteamFlag = support.appendingPathComponent("show-steam")
    static let appsOut = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PortKit Games", isDirectory: true)

    static var gamesRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: "gamesRoot"), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return support.appendingPathComponent("games", isDirectory: true)
    }

    static var windowsSteamExe: URL {
        prefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }

    static func ensure(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

struct PortKitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Collects partial output chunks and emits complete lines (splitting on \n and \r,
/// since steamcmd redraws progress with carriage returns). Interactive prompts such as
/// "Steam Guard code:" never end in a newline, so they are emitted as soon as they appear.
final class LineBuffer: @unchecked Sendable {
    private var pending = ""
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void
    static let promptPattern = try! NSRegularExpression(pattern: #"(?i)(code|password)[^:\n]*:\s*$"#)

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return }
        feed(text)
    }

    func feed(_ text: String) {
        lock.lock()
        pending += text
        var lines: [String] = []
        while let idx = pending.firstIndex(where: \.isNewline) {   // "\r\n" is one Character, so match by property
            lines.append(String(pending[..<idx]))
            pending = String(pending[pending.index(after: idx)...])
        }
        let ns = pending as NSString
        if Self.promptPattern.firstMatch(in: pending, range: NSRange(location: 0, length: ns.length)) != nil {
            lines.append(pending)
            pending = ""
        }
        lock.unlock()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine(line) }
    }

    func flush() {
        lock.lock(); let rest = pending; pending = ""; lock.unlock()
        if !rest.trimmingCharacters(in: .whitespaces).isEmpty { onLine(rest) }
    }
}

/// Handle to a running child process that can be cancelled along with everything it spawned.
final class RunningProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }

    func cancel() {
        guard process.isRunning else { return }
        Self.killTree(process.processIdentifier)
    }

    /// Foundation's terminate() only signals the direct child; wine and steamcmd fork helpers.
    static func killTree(_ pid: pid_t) {
        for child in children(of: pid) { killTree(child) }
        kill(pid, SIGTERM)
    }

    private static func children(of pid: pid_t) -> [pid_t] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
    }
}

enum ProcessRunner {
    /// Runs a process, streaming stdout+stderr line by line. Returns the exit status.
    @discardableResult
    static func run(_ executable: URL,
                    _ args: [String],
                    env: [String: String] = [:],
                    cwd: URL? = nil,
                    started: (@Sendable (RunningProcess) -> Void)? = nil,
                    onLine: @escaping @Sendable (String) -> Void = { _ in }) async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = executable
            p.arguments = args
            var environment = ProcessInfo.processInfo.environment
            environment.merge(env) { _, new in new }
            p.environment = environment
            if let cwd { p.currentDirectoryURL = cwd }
            p.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let buffer = LineBuffer(onLine: onLine)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { buffer.feed(d) }
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { buffer.feed(rest) }
                buffer.flush()
                cont.resume(returning: proc.terminationStatus)
            }
            do {
                try p.run()
                started?(RunningProcess(p))
            } catch {
                onLine("Failed to start \(executable.path): \(error.localizedDescription)")
                cont.resume(returning: -1)
            }
        }
    }

    static func capture(_ executable: String, _ args: [String], env: [String: String] = [:]) async -> (Int32, String) {
        let collected = Collected()
        let status = await run(URL(fileURLWithPath: executable), args, env: env, onLine: { collected.append($0) })
        return (status, collected.text)
    }

    final class Collected: @unchecked Sendable {
        private var lines: [String] = []
        private let lock = NSLock()
        func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }
}

enum Net {
    static func download(_ url: URL, to dest: URL) async throws {
        var req = URLRequest(url: url)
        req.setValue("PortKit", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PortKitError("Download failed (HTTP \(http.statusCode)) for \(url.absoluteString)")
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    static func json<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue("PortKit", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PortKitError("Request failed (HTTP \(http.statusCode)) for \(url.host ?? "server")")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    struct GitHubRelease: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
    }

    static func latestRelease(_ repo: String) async throws -> GitHubRelease {
        try await json(GitHubRelease.self, from: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
    }

    static func release(_ repo: String, tag: String) async throws -> GitHubRelease {
        try await json(GitHubRelease.self, from: URL(string: "https://api.github.com/repos/\(repo)/releases/tags/\(tag)")!)
    }
}

extension String {
    /// Single-quote for bash.
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }

    var fileSafe: String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = components(separatedBy: bad).joined(separator: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return cleaned.isEmpty ? "Game" : cleaned
    }

    /// Splits a command line the way a shell would for simple cases: whitespace-separated,
    /// with single or double quotes grouping words.
    var argumentWords: [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var inWord = false
        for ch in self {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; inWord = true
            } else if ch.isWhitespace {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(ch); inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }
}
