import Foundation

public enum StateStore {
    public static var directoryURL: URL {
        AppPaths.applicationSupport
    }

    public static var fileURL: URL {
        AppPaths.stateFile
    }

    public static func load() -> PersistedState {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return PersistedState.fresh()
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let state = try decoder.decode(PersistedState.self, from: data)
            return normalize(state)
        } catch {
            backupCorruptFile()
            return PersistedState.fresh()
        }
    }

    public static func save(_ state: PersistedState) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalize(state))
            try data.write(to: fileURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
        } catch {
            // Persistencia best-effort: la app sigue funcionando en memoria.
        }
    }

    public static func reset() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    public static func encodeExport(_ payload: ExportPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    public static func decodeExport(_ data: Data) throws -> ExportPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ExportPayload.self, from: data)
    }

    private static func normalize(_ state: PersistedState) -> PersistedState {
        var normalized = state
        let wasLegacy = normalized.version < 2
        normalized.version = 2

        var subscriptions = normalized.settings.subscriptions
        for provider in ProviderID.allCases where !subscriptions.contains(where: { $0.id == provider }) {
            subscriptions.append(.default(for: provider))
        }

        var seen: Set<ProviderID> = []
        subscriptions = subscriptions.compactMap { subscription in
            guard !seen.contains(subscription.id) else { return nil }
            seen.insert(subscription.id)
            var subscription = subscription
            if subscription.planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                subscription.planName = subscription.id.defaultPlanName
            }
            if subscription.id == .liteLLM,
               subscription.planName.caseInsensitiveCompare("Corporate") == .orderedSame,
               subscription.priceSource == .auto {
                subscription.planName = subscription.id.defaultPlanName
            }
            subscription.monthlyPriceUSD = max(0, subscription.monthlyPriceUSD)

            // Migración desde la versión 1: si el plan y el precio coinciden con
            // el catálogo, el valor era el de referencia y puede actualizarse
            // automáticamente. Un precio distinto se conserva como manual.
            if wasLegacy,
               subscription.priceSource == .manual,
               let option = subscription.id.planOption(named: subscription.planName),
               abs(option.priceUSD - subscription.monthlyPriceUSD) < 0.005 {
                subscription.priceSource = .auto
            }

            return subscription
        }

        let order = Dictionary(uniqueKeysWithValues: ProviderID.allCases.enumerated().map { ($1, $0) })
        subscriptions.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        normalized.settings.subscriptions = subscriptions

        // Migrate cooldown keys for LiteLLM alerts when restoring earlier data.
        let legacyAlertPrefix = ProviderID.legacyLiteLLMIdentifier + "|"
        let legacyAlertEntries = normalized.alertKeys.filter { $0.key.hasPrefix(legacyAlertPrefix) }
        for (key, date) in legacyAlertEntries {
            let suffix = key.dropFirst(legacyAlertPrefix.count)
            let migratedKey = "\(ProviderID.liteLLM.rawValue)|\(suffix)"
            if normalized.alertKeys[migratedKey].map({ $0 < date }) ?? true {
                normalized.alertKeys[migratedKey] = date
            }
            normalized.alertKeys.removeValue(forKey: key)
        }

        normalized.settings.refreshMinutes = max(
            AppSettings.minimumRefreshMinutes,
            normalized.settings.refreshMinutes
        )
        if normalized.settings.menuBarMode == .monthlyCost {
            normalized.settings.menuBarMode = .compact
        }
        normalized.settings.alertThresholds = normalized.settings.alertThresholds
            .filter { $0 > 0 && $0 <= 100 }
            .sorted()
        if normalized.settings.alertThresholds.isEmpty {
            normalized.settings.alertThresholds = [75, 90, 100]
        }

        return normalized
    }

    private static func backupCorruptFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = formatter.string(from: Date())
        let backup = directoryURL.appendingPathComponent("state.corrupt-\(suffix).json")
        try? FileManager.default.copyItem(at: fileURL, to: backup)
    }
}

public struct ExportPayload: Codable {
    public var exportedAt: Date
    public var settings: AppSettings
    public var history: [String: [DailyUsage]]
    public var alerts: [AppAlert]

    public init(
        exportedAt: Date = Date(),
        settings: AppSettings,
        history: [String: [DailyUsage]],
        alerts: [AppAlert]
    ) {
        self.exportedAt = exportedAt
        self.settings = settings
        self.history = history
        self.alerts = alerts
    }
}
