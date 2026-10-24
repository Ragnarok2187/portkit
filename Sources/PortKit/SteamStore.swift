import Foundation

struct Platforms: Codable, Hashable {
    var windows: Bool
    var mac: Bool
    var linux: Bool
}

struct StoreItem: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let tiny_image: String?
    let platforms: Platforms?

    var isWindowsOnly: Bool { (platforms?.windows ?? false) && !(platforms?.mac ?? false) }
}

struct AppDetails: Decodable {
    let name: String
    let header_image: String?
    let platforms: Platforms?
}

/// Public Steam storefront endpoints (no API key needed).
enum SteamStore {
    private struct SearchResponse: Decodable { let items: [StoreItem] }
    private struct DetailsWrapper: Decodable { let success: Bool; let data: AppDetails? }

    static func search(_ term: String) async throws -> [StoreItem] {
        var c = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        c.queryItems = [.init(name: "term", value: term), .init(name: "cc", value: "us"), .init(name: "l", value: "en")]
        return try await Net.json(SearchResponse.self, from: c.url!).items
    }

    static func details(_ appID: Int) async throws -> AppDetails {
        let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(appID)&filters=basic,platforms")!
        let map = try await Net.json([String: DetailsWrapper].self, from: url)
        guard let d = map[String(appID)]?.data else {
            throw PortKitError("Steam has no store page for app \(appID).")
        }
        return d
    }
}
