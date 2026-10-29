import Foundation

// MARK: - Actualizaciones desde GitHub Releases

public struct AppUpdate: Hashable, Sendable {
    public let version: String
    public let name: String
    public let notes: String
    public let pageURL: URL
    public let dmgURL: URL
    public let publishedAt: Date?

    public init(
        version: String,
        name: String,
        notes: String,
        pageURL: URL,
        dmgURL: URL,
        publishedAt: Date? = nil
    ) {
        self.version = version
        self.name = name
        self.notes = notes
        self.pageURL = pageURL
        self.dmgURL = dmgURL
        self.publishedAt = publishedAt
    }
}

public enum UpdateChecker {
    public static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/KemelMoh/usage-tracker/releases/latest"
    )!

    /// Devuelve la última release si existe y tiene un DMG. Un 404 significa que
    /// el repositorio no es público o que todavía no hay releases.
    public static func latest() async throws -> AppUpdate? {
        let (data, _) = try await HTTPClient.shared.get(
            url: latestReleaseURL,
            headers: [
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "UsageTracker/0.1"
            ]
        )
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> AppUpdate? {
        let release: GitHubRelease
        do {
            release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }

        guard let version = normalizedVersion(release.tagName) else { return nil }
        guard let dmg = release.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") }),
              let dmgURL = URL(string: dmg.browserDownloadURL) else {
            return nil
        }
        guard let pageURL = URL(string: release.htmlURL) else { return nil }

        return AppUpdate(
            version: version,
            name: release.name ?? "Usage Tracker \(version)",
            notes: release.body ?? "",
            pageURL: pageURL,
            dmgURL: dmgURL,
            publishedAt: release.publishedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        )
    }

    /// Compara versiones numéricas. Ignora una `v` inicial y componentes no numéricos.
    public static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let remoteVersion = SemanticVersion(remote),
              let currentVersion = SemanticVersion(current) else {
            return false
        }
        return remoteVersion > currentVersion
    }

    public static func normalizedVersion(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutV = value.hasPrefix("v") || value.hasPrefix("V")
            ? String(value.dropFirst())
            : value
        guard SemanticVersion(withoutV) != nil else { return nil }
        return withoutV
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlURL: String
        let publishedAt: String?
        let assets: [Asset]

        private enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            private enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }

    private struct SemanticVersion: Comparable {
        let components: [Int]

        init?(_ raw: String) {
            var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("v") || value.hasPrefix("V") {
                value = String(value.dropFirst())
            }
            guard !value.isEmpty else { return nil }
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty else { return nil }
            var numbers: [Int] = []
            for part in parts {
                let digits = part.prefix { $0.isNumber }
                guard !digits.isEmpty, let number = Int(digits) else { return nil }
                numbers.append(number)
            }
            while numbers.count < 3 { numbers.append(0) }
            components = numbers
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            let count = max(lhs.components.count, rhs.components.count)
            for index in 0..<count {
                let left = index < lhs.components.count ? lhs.components[index] : 0
                let right = index < rhs.components.count ? rhs.components[index] : 0
                if left != right { return left < right }
            }
            return false
        }
    }
}
