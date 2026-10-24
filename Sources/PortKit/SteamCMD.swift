import Foundation

/// Wraps Valve's official SteamCMD client. Ownership is enforced by Steam: only games
/// on the signed-in account can be downloaded.
enum SteamCMD {
    static let tarballURL = URL(string: "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz")!

    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Paths.steamcmdBinary.path) }

    static func install(log: @escaping @Sendable (String) -> Void) async throws {
        Paths.ensure(Paths.steamcmdDir)
        let tar = Paths.steamcmdDir.appendingPathComponent("steamcmd_osx.tar.gz")
        log("Downloading SteamCMD…")
        try await Net.download(tarballURL, to: tar)
        let status = await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"),
                                             ["-xzf", tar.path, "-C", Paths.steamcmdDir.path], onLine: log)
        try? FileManager.default.removeItem(at: tar)
        guard status == 0, isInstalled else { throw PortKitError("Could not extract SteamCMD.") }
        log("Bootstrapping SteamCMD (first run downloads its own updates)…")
        let code = await run(["+quit"], log: log)
        guard code == 0 else { throw PortKitError("SteamCMD failed to start (exit \(code)). See Activity for details.") }
    }

    // MARK: Login

    enum LoginOutcome: Equatable { case ok, needsGuardCode, failed(String) }

    static func classifyLogin(_ out: String) -> LoginOutcome {
        let lower = out.lowercased()
        if lower.contains("waiting for user info...ok")
            || (lower.contains("logging in user") && lower.contains("to steam public...ok")) {
            return .ok
        }
        if lower.contains("invalid password") { return .failed("Wrong username or password.") }
        if lower.contains("rate limit") { return .failed("Steam is rate-limiting sign-ins. Wait about 30 minutes and try again.") }
        let guardHints = ["steam guard", "two-factor", "two factor", "account logon denied", "accountlogindeniedneedtwofactor",
                          "invalidloginauthcode", "invalid login auth code", "authcode"]
        if guardHints.contains(where: lower.contains) { return .needsGuardCode }
        let reason = out.components(separatedBy: "\n").last(where: { $0.contains("FAILED") || $0.contains("ERROR") })
        return .failed(reason?.trimmingCharacters(in: .whitespaces) ?? "Sign-in failed. See Activity for details.")
    }

    /// Logs in once with a password; SteamCMD caches a login token so later commands only need the username.
    /// The password goes through a private runscript file, never the command line (which other processes can read).
    static func login(user: String, password: String, guardCode: String?,
                      started: @escaping @Sendable (RunningProcess) -> Void,
                      log: @escaping @Sendable (String) -> Void) async -> LoginOutcome {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("portkit-login-\(UUID().uuidString).txt")
        var line = "login \(quote(user)) \(quote(password))"
        if let guardCode, !guardCode.isEmpty { line += " \(quote(guardCode))" }
        let contents = "@NoPromptForPassword 1\n\(line)\nquit\n"
        guard FileManager.default.createFile(atPath: script.path, contents: Data(contents.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            return .failed("Could not write a temporary file for sign-in.")
        }
        defer { try? FileManager.default.removeItem(at: script) }

        let seen = ProcessRunner.Collected()
        let handle = HandleBox()
        await run(["+runscript", script.path], started: { p in handle.set(p); started(p) }) { line in
            seen.append(line)
            log(line)
            // SteamCMD waits on stdin for a code it can't get; stop it and ask the user instead.
            if line.range(of: #"(?i)(steam guard|two-factor|auth) code[^:]*:\s*$"#, options: .regularExpression) != nil {
                handle.cancel()
            }
        }
        return classifyLogin(seen.text)
    }

    // MARK: Download

    enum DownloadOutcome: Equatable { case success, notOwned, notSignedIn, diskFull, retryable(String), failed(String) }

    static func classifyDownload(_ out: String, appID: Int) -> DownloadOutcome {
        if out.contains("Success! App '\(appID)' fully installed") || out.contains("Success! App '\(appID)' already up to date") {
            return .success
        }
        let lower = out.lowercased()
        if lower.contains("no subscription") { return .notOwned }
        if lower.contains("cached credentials not found") || lower.contains("login failure")
            || lower.contains("invalid password") || lower.contains("not logged on") {
            return .notSignedIn
        }
        if lower.contains("not enough disk space") || lower.contains("disk write failure") || lower.contains("0x202") {
            return .diskFull
        }
        let last = out.components(separatedBy: "\n").last(where: { $0.contains("ERROR") || $0.contains("FAILED") })?
            .trimmingCharacters(in: .whitespaces) ?? "Download failed."
        let transient = ["state is 0x", "missing configuration", "timeout", "no connection", "rate limit", "service unavailable"]
        if transient.contains(where: lower.contains) { return .retryable(last) }
        return .failed(last)
    }

    /// Downloads (or updates) the Windows depots of an app, regardless of the host OS. Retries transient failures.
    static func downloadWindowsApp(appID: Int, user: String, into dir: URL, validate: Bool,
                                   started: @escaping @Sendable (RunningProcess) -> Void,
                                   progress: @escaping @Sendable (Double) -> Void,
                                   log: @escaping @Sendable (String) -> Void) async throws {
        Paths.ensure(dir)
        var attempt = 1
        while true {
            let seen = ProcessRunner.Collected()
            var args = ["+@NoPromptForPassword", "1",
                        "+@sSteamCmdForcePlatformType", "windows",
                        "+force_install_dir", dir.path,
                        "+login", user,
                        "+app_update", String(appID)]
            if validate { args.append("validate") }
            args.append("+quit")
            await run(args, started: started) { line in
                seen.append(line)
                if let v = parseProgress(line) { progress(v) }
                log(line)
            }
            switch classifyDownload(seen.text, appID: appID) {
            case .success: return
            case .notOwned: throw PortKitError("Your Steam account doesn't own app \(appID).")
            case .notSignedIn: throw PortKitError("SteamCMD's saved sign-in has expired. Sign in again on the Setup page.")
            case .diskFull: throw PortKitError("Not enough disk space. Free some space or choose another game folder in Setup.")
            case .failed(let reason): throw PortKitError(reason)
            case .retryable(let reason):
                guard attempt < 3 else { throw PortKitError(reason) }
                attempt += 1
                log("Transient error (\(reason)); retrying (attempt \(attempt) of 3)…")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private static let progressRegex = try! NSRegularExpression(pattern: #"progress:\s*([0-9]+(?:\.[0-9]+)?)"#)

    static func parseProgress(_ line: String) -> Double? {
        let ns = line as NSString
        guard let m = progressRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let v = Double(ns.substring(with: m.range(at: 1))) else { return nil }
        return min(max(v / 100, 0), 1)
    }

    /// Runs the steamcmd binary directly (Valve's wrapper script breaks on paths with spaces),
    /// repeating while it exits with 42, its "restart after self-update" code.
    @discardableResult
    static func run(_ args: [String], started: (@Sendable (RunningProcess) -> Void)? = nil,
                    log: @escaping @Sendable (String) -> Void) async -> Int32 {
        let dir = Paths.steamcmdDir.path
        let env = ["DYLD_LIBRARY_PATH": dir, "DYLD_FRAMEWORK_PATH": dir]
        var status: Int32 = 0
        for _ in 0..<4 {
            status = await ProcessRunner.run(Paths.steamcmdBinary, args, env: env, cwd: Paths.steamcmdDir,
                                             started: started, onLine: log)
            if status != 42 { break }
            log("SteamCMD updated itself; restarting…")
        }
        return status
    }

    private static func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "") + "\"" }

    private final class HandleBox: @unchecked Sendable {
        private var p: RunningProcess?
        private let lock = NSLock()
        func set(_ p: RunningProcess) { lock.lock(); self.p = p; lock.unlock() }
        func cancel() { lock.lock(); let p = self.p; lock.unlock(); p?.cancel() }
    }
}
