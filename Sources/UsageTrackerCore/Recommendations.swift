import Foundation

// MARK: - Recomendaciones por proveedor

public enum WorkloadBadge: String, CaseIterable, Codable, Sendable {
    case ultra
    case medium
    case light

    public var title: String {
        switch self {
        case .ultra: return "Ultra work"
        case .medium: return "Medium work"
        case .light: return "Light work"
        }
    }

    public var symbolName: String {
        switch self {
        case .ultra: return "crown.fill"
        case .medium: return "gauge.with.dots.needle.50percent"
        case .light: return "leaf.fill"
        }
    }

    /// Tope de precio de entrada por millón de tokens.
    public var maxInputPerMillion: Double {
        switch self {
        case .ultra: return 5.00
        case .medium: return 2.50
        case .light: return 0.50
        }
    }

    /// Tope de precio de salida por millón de tokens.
    public var maxOutputPerMillion: Double {
        switch self {
        case .ultra: return 25.00
        case .medium: return 12.50
        case .light: return 2.50
        }
    }
}

public struct ModelRecommendation: Identifiable, Hashable, Sendable {
    public let model: CatalogModel
    public let badge: WorkloadBadge

    public var id: String { "\(model.id)#\(badge.rawValue)" }

    public init(model: CatalogModel, badge: WorkloadBadge) {
        self.model = model
        self.badge = badge
    }
}

public enum ModelRecommender {
    /// Devuelve hasta tres modelos distintos de un proveedor, uno por badge.
    /// Solo entran modelos con precio conocido, no gratuitos, no deprecated y
    /// publicados en los últimos seis meses. Cada badge tiene un tope de precio.
    public static func recommendations(
        for provider: ProviderID,
        from models: [CatalogModel],
        now: Date = Date()
    ) -> [ModelRecommendation] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now)
            ?? now.addingTimeInterval(-183 * 86_400)

        let eligible = models.filter { model in
            guard model.provider == provider else { return false }
            guard !model.isFree, !model.isDeprecated else { return false }
            guard let input = model.inputPerMillion, input > 0,
                  let output = model.outputPerMillion, output > 0 else {
                return false
            }
            guard let date = model.referenceDate,
                  date >= cutoff,
                  date <= now else {
                return false
            }
            return true
        }

        guard !eligible.isEmpty else { return [] }

        var candidates = eligible.map { model in
            Candidate(
                model: model,
                cost: cost(for: model),
                contextScore: contextScore(for: model),
                recencyScore: recencyScore(for: model, now: now)
            )
        }

        // Si dos entradas son variantes del mismo modelo, se recomienda una sola.
        var byCanonical: [String: Candidate] = [:]
        for candidate in candidates {
            let key = candidate.model.canonicalModelID ?? candidate.model.modelID
            if let existing = byCanonical[key] {
                if isBetter(candidate, than: existing) {
                    byCanonical[key] = candidate
                }
            } else {
                byCanonical[key] = candidate
            }
        }
        candidates = Array(byCanonical.values)

        // Bandas de precio: Light es lo más barato; Medium sube el tope; Ultra
        // es la banda premium, pero también con un máximo.
        let lightPool = candidates.filter { fits($0.model, .light) }
        let mediumPool = candidates.filter {
            fits($0.model, .medium) && !fits($0.model, .light)
        }
        let ultraPool = candidates.filter {
            fits($0.model, .ultra) && !fits($0.model, .medium)
        }

        var selected: [(candidate: Candidate, badge: WorkloadBadge)] = []
        var used: Set<String> = []

        func add(_ candidate: Candidate?, as badge: WorkloadBadge) {
            guard let candidate, !used.contains(candidate.model.id) else { return }
            selected.append((candidate, badge))
            used.insert(candidate.model.id)
        }

        add(best(in: ultraPool, excluding: used), as: .ultra)
        add(best(in: mediumPool, excluding: used), as: .medium)
        add(best(in: lightPool, excluding: used), as: .light)

        // Si una banda quedó vacía, se rellena con otro modelo que respete el
        // tope de ese badge, sin repetir modelo.
        for badge in [WorkloadBadge.ultra, .medium, .light]
            where !selected.contains(where: { $0.badge == badge }) {
            let fallback = candidates.filter {
                fits($0.model, badge) && !used.contains($0.model.id)
            }
            add(best(in: fallback, excluding: used), as: badge)
        }

        return selected
            .sorted { badgeOrder($0.badge) < badgeOrder($1.badge) }
            .map { ModelRecommendation(model: $0.candidate.model, badge: $0.badge) }
    }

    private struct Candidate {
        let model: CatalogModel
        let cost: Double
        let contextScore: Double
        let recencyScore: Double

        /// Capacidad estimada sin usar benchmarks: contexto y recencia.
        var capabilityScore: Double {
            0.65 * contextScore + 0.35 * recencyScore
        }
    }

    private static func fits(_ model: CatalogModel, _ badge: WorkloadBadge) -> Bool {
        guard let input = model.inputPerMillion,
              let output = model.outputPerMillion else {
            return false
        }
        return input <= badge.maxInputPerMillion
            && output <= badge.maxOutputPerMillion
    }

    private static func best(
        in candidates: [Candidate],
        excluding used: Set<String>
    ) -> Candidate? {
        candidates
            .filter { !used.contains($0.model.id) }
            .sorted(by: { isBetter($0, than: $1) })
            .first
    }

    /// Mejor capacidad; a igualdad, menor precio, más contexto y más reciente.
    private static func isBetter(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if abs(lhs.capabilityScore - rhs.capabilityScore) > 0.000_001 {
            return lhs.capabilityScore > rhs.capabilityScore
        }
        if abs(lhs.cost - rhs.cost) > 0.000_001 { return lhs.cost < rhs.cost }
        let leftContext = lhs.model.contextWindow ?? 0
        let rightContext = rhs.model.contextWindow ?? 0
        if leftContext != rightContext { return leftContext > rightContext }
        let leftDate = lhs.model.referenceDate ?? .distantPast
        let rightDate = rhs.model.referenceDate ?? .distantPast
        if leftDate != rightDate { return leftDate > rightDate }
        return lhs.model.modelID < rhs.model.modelID
    }

    private static func contextScore(for model: CatalogModel) -> Double {
        let context = Double(max(model.contextWindow ?? 0, 1))
        return clamp(
            log2(context / 16_000) / log2(1_000_000 / 16_000),
            lower: 0,
            upper: 1
        )
    }

    private static func recencyScore(for model: CatalogModel, now: Date) -> Double {
        guard let date = model.referenceDate else { return 0 }
        let ageDays = max(0, now.timeIntervalSince(date) / 86_400)
        return clamp(1 - ageDays / 183, lower: 0, upper: 1)
    }

    /// Coste de referencia: 100K tokens de entrada + 20K de salida.
    private static func cost(for model: CatalogModel) -> Double {
        let input = model.inputPerMillion ?? 0
        let output = model.outputPerMillion ?? 0
        return input * 0.1 + output * 0.02
    }

    private static func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private static func badgeOrder(_ badge: WorkloadBadge) -> Int {
        switch badge {
        case .ultra: return 0
        case .medium: return 1
        case .light: return 2
        }
    }
}
