import AppKit
import Foundation

/// Shows Windows Steam's windows inside PortKit.
///
/// Steam's UI is Chromium (CEF). Under Wine on macOS its pages render fine, but the native
/// windows they are presented in stay black. Steam is started with `-cef-enable-debugging`,
/// which serves the Chrome DevTools Protocol on 127.0.0.1:8080; PortKit captures each page
/// from there and forwards clicks and typing back.
@MainActor
final class SteamUI: ObservableObject {
    struct Page: Decodable, Identifiable, Hashable {
        let id: String
        let title: String
        let type: String
        let url: String
        let webSocketDebuggerUrl: String?
    }

    @Published var pages: [Page] = []
    @Published var selected: Page?
    @Published var image: NSImage?
    @Published var status = "Starting Steam for Windows…"

    private var socket: URLSessionWebSocketTask?
    private var socketPageID: String?
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var pollTask: Task<Void, Never>?
    static let endpoint = URL(string: "http://127.0.0.1:8080/json")!

    /// Steam's own top-level windows. Embedded store/community views (https URLs), the hidden JS host,
    /// and the pre-created menus and nav flyouts are not windows a person needs to see.
    nonisolated static func visiblePages(_ all: [Page]) -> [Page] {
        all.filter { p in
            p.type == "page" && !p.title.isEmpty && p.url.hasPrefix("about:blank")
                && !p.title.hasSuffix("Menu") && !p.title.hasSuffix("Supernav")
                && !p.title.hasPrefix("Steam Big Picture")
        }
    }

    /// Which window to show: sign-in first, then any window that just appeared (a dialog), then Steam's main window.
    nonisolated static func preferred(_ pages: [Page], newIDs: Set<String>) -> Page? {
        pages.first { $0.title.localizedCaseInsensitiveContains("sign in") }
            ?? pages.first { newIDs.contains($0.id) && $0.title != "Friends List" && $0.title != "Special Offers" }
            ?? pages.first { $0.title == "Steam" }
            ?? pages.first
    }

    private var seenIDs: Set<String> = []

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if tick % 6 == 0 { await self.refreshPages() }
                await self.capture()
                tick += 1
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        disconnect()
    }

    func select(_ page: Page) {
        guard page.id != selected?.id else { return }
        selected = page
        image = nil
        disconnect()
    }

    private func refreshPages() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.endpoint)
            let found = Self.visiblePages(try JSONDecoder().decode([Page].self, from: data))
            let newIDs = seenIDs.isEmpty ? [] : Set(found.map(\.id)).subtracting(seenIDs)
            seenIDs.formUnion(found.map(\.id))
            pages = found
            if let current = selected, !found.contains(where: { $0.id == current.id }) {
                selected = nil
                disconnect()
            }
            // Jump to a dialog that just opened; otherwise keep what the user picked.
            if selected == nil || !newIDs.isEmpty, let pick = Self.preferred(found, newIDs: newIDs), pick.id != selected?.id {
                select(pick)
            }
            status = found.isEmpty ? "Steam is running but has no windows open." : ""
        } catch {
            pages = []
            status = "Waiting for Steam for Windows to start…"
        }
    }

    private func capture() async {
        guard let page = selected else { image = nil; return }
        do {
            let result = try await call("Page.captureScreenshot", ["format": "png"], on: page)
            if let b64 = result["data"] as? String, let data = Data(base64Encoded: b64), let img = NSImage(data: data) {
                image = img
            }
        } catch {
            disconnect()
        }
    }

    // MARK: Input

    /// `point` is in the page's CSS pixels (the same space as the captured image).
    func click(at point: CGPoint) {
        guard let page = selected else { return }
        Task {
            for type in ["mousePressed", "mouseReleased"] {
                _ = try? await call("Input.dispatchMouseEvent",
                                    ["type": type, "x": point.x, "y": point.y, "button": "left", "clickCount": 1], on: page)
            }
        }
    }

    func scroll(at point: CGPoint, by deltaY: CGFloat) {
        guard let page = selected else { return }
        Task {
            _ = try? await call("Input.dispatchMouseEvent",
                                ["type": "mouseWheel", "x": point.x, "y": point.y, "deltaX": 0, "deltaY": deltaY], on: page)
        }
    }

    func type(_ text: String) {
        guard let page = selected, !text.isEmpty else { return }
        Task { _ = try? await call("Input.insertText", ["text": text], on: page) }
    }

    enum Key: String { case enter = "Enter", tab = "Tab", backspace = "Backspace", escape = "Escape" }

    func press(_ key: Key) {
        guard let page = selected else { return }
        let code: Int = switch key { case .enter: 13; case .tab: 9; case .backspace: 8; case .escape: 27 }
        Task {
            for type in ["rawKeyDown", "keyUp"] {
                var params: [String: Any] = ["type": type, "key": key.rawValue, "code": key.rawValue,
                                             "windowsVirtualKeyCode": code, "nativeVirtualKeyCode": code]
                if key == .enter && type == "rawKeyDown" { params["text"] = "\r" }
                _ = try? await call("Input.dispatchKeyEvent", params, on: page)
            }
            if key == .enter {
                _ = try? await call("Input.dispatchKeyEvent", ["type": "char", "key": "Enter", "text": "\r",
                                                               "windowsVirtualKeyCode": 13], on: page)
            }
        }
    }

    // MARK: DevTools protocol

    private func call(_ method: String, _ params: [String: Any], on page: Page) async throws -> [String: Any] {
        let ws = try connect(page)
        let id = nextID
        nextID += 1
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        return try await withCheckedThrowingContinuation { cont in
            waiting[id] = cont
            ws.send(.string(String(decoding: payload, as: UTF8.self))) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.waiting.removeValue(forKey: id)?.resume(throwing: error) }
            }
            // Never hang the poll loop on a reply that doesn't come.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.waiting.removeValue(forKey: id)?.resume(throwing: PortKitError("Steam did not respond."))
            }
        }
    }

    private func connect(_ page: Page) throws -> URLSessionWebSocketTask {
        if let socket, socketPageID == page.id { return socket }
        disconnect()
        guard let s = page.webSocketDebuggerUrl, let url = URL(string: s), url.host == "127.0.0.1" || url.host == "localhost" else {
            throw PortKitError("This Steam window can't be shown.")
        }
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.maximumMessageSize = 64 * 1024 * 1024
        socket = ws
        socketPageID = page.id
        ws.resume()
        receive(ws)
        return ws
    }

    private func receive(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === ws else { return }
                switch result {
                case .failure:
                    self.disconnect()
                case .success(let message):
                    let data: Data? = switch message {
                    case .string(let s): Data(s.utf8)
                    case .data(let d): d
                    @unknown default: nil
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let id = obj["id"] as? Int, let cont = self.waiting.removeValue(forKey: id) {
                        if let err = obj["error"] as? [String: Any] {
                            cont.resume(throwing: PortKitError(err["message"] as? String ?? "DevTools error"))
                        } else {
                            cont.resume(returning: obj["result"] as? [String: Any] ?? [:])
                        }
                    }
                    self.receive(ws)
                }
            }
        }
    }

    private func disconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        socketPageID = nil
        for (_, cont) in waiting { cont.resume(throwing: PortKitError("Disconnected")) }
        waiting.removeAll()
    }
}
