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
}

/// Topes de precio de una banda de trabajo, en USD por millón de tokens.
public struct WorkloadPriceCap: Hashable, Sendable {
    public let maxInputPerMillion: Double
    public let maxOutputPerMillion: Double

    public init(maxInputPerMillion: Double, maxOutputPerMillion: Double) {
        self.maxInputPerMillion = maxInputPerMillion
        self.maxOutputPerMillion = maxOutputPerMillion
    }
}

/// Topes de precio por proveedor y banda.
///
/// No todos los proveedores tienen la misma economía de precios. Claude y
/// Copilot llegan a modelos de $10 por millón de entrada, pero el catálogo de
/// OpenCode Go se mueve entre $0.10 y $3. Usar los mismos topes para todos
/// hacía que en OpenCode Go la banda "ultra" no discriminara nada y dejara un
/// salto de precio de 20× entre la banda más alta y la más baja.
public enum WorkloadPriceCaps {
    /// Topes por defecto, usados por Claude y Copilot.
    public static let standard: [WorkloadBadge: WorkloadPriceCap] = [
        .ultra: WorkloadPriceCap(maxInputPerMillion: 5.00, maxOutputPerMillion: 25.00),
        .medium: WorkloadPriceCap(maxInputPerMillion: 2.50, maxOutputPerMillion: 12.50),
        .light: WorkloadPriceCap(maxInputPerMillion: 0.50, maxOutputPerMillion: 2.50)
    ]

    /// Topes de OpenCode Go, ajustados a su catálogo real.
    public static let openCodeGo: [WorkloadBadge: WorkloadPriceCap] = [
        .ultra: WorkloadPriceCap(maxInputPerMillion: 2.00, maxOutputPerMillion: 10.00),
        .medium: WorkloadPriceCap(maxInputPerMillion: 1.50, maxOutputPerMillion: 6.00),
        .light: WorkloadPriceCap(maxInputPerMillion: 0.40, maxOutputPerMillion: 1.60)
    ]

    /// Topes que aplican a un proveedor.
    public static func caps(for provider: ProviderID) -> [WorkloadBadge: WorkloadPriceCap] {
        switch provider {
        case .opencodeGo: return openCodeGo
        case .claude, .copilot: return standard
        }
    }

    /// Tope de una banda para un proveedor.
    public static func cap(
        _ badge: WorkloadBadge,
        for provider: ProviderID
    ) -> WorkloadPriceCap {
        caps(for: provider)[badge] ?? standard[badge]!
    }
}

extension WorkloadBadge {
    /// Tope de precio de entrada por millón de tokens.
    ///
    /// Valor por defecto, sin ajuste por proveedor. Para las recomendaciones
    /// hay que usar `WorkloadPriceCaps.cap(_:for:)`.
    public var maxInputPerMillion: Double {
        WorkloadPriceCaps.standard[self]?.maxInputPerMillion ?? .infinity
    }

    /// Tope de precio de salida por millón de tokens.
    ///
    /// Valor por defecto, sin ajuste por proveedor. Para las recomendaciones
    /// hay que usar `WorkloadPriceCaps.cap(_:for:)`.
    public var maxOutputPerMillion: Double {
        WorkloadPriceCaps.standard[self]?.maxOutputPerMillion ?? .infinity
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

/// Índice de recomendaciones ya calculado para un catálogo concreto.
///
/// Recomputar las recomendaciones recorre y ordena el catálogo entero por
/// proveedor. La interfaz lo usa muchas veces por cada pasada de render, así
/// que se calcula una sola vez cuando cambia el catálogo y se reutiliza.
public struct RecommendationIndex: Sendable {
    /// Recomendaciones agrupadas por proveedor.
    public let byProvider: [ProviderID: [ModelRecommendation]]
    /// Badge de cada modelo recomendado, indexado por id de modelo.
    public let badgeByModelID: [String: WorkloadBadge]
    /// Posición de cada modelo recomendado dentro de su proveedor.
    public let orderByModelID: [String: Int]
    /// Ids de todos los modelos recomendados.
    public let recommendedModelIDs: Set<String>
    /// Proveedores con menos de tres modelos válidos.
    public let providersBelowMinimum: [ProviderID]

    public static let empty = RecommendationIndex(byProvider: [:])

    public init(byProvider: [ProviderID: [ModelRecommendation]]) {
        self.byProvider = byProvider

        var badgeByModelID: [String: WorkloadBadge] = [:]
        var orderByModelID: [String: Int] = [:]
        for recommendations in byProvider.values {
            for (index, recommendation) in recommendations.enumerated() {
                badgeByModelID[recommendation.model.id] = recommendation.badge
                orderByModelID[recommendation.model.id] = index
            }
        }
        self.badgeByModelID = badgeByModelID
        self.orderByModelID = orderByModelID
        self.recommendedModelIDs = Set(badgeByModelID.keys)
        self.providersBelowMinimum = ProviderID.allCases.filter {
            (byProvider[$0]?.count ?? 0) < 3
        }
    }

    /// Calcula el índice para todos los proveedores de un catálogo.
    public static func build(
        from models: [CatalogModel],
        now: Date = Date()
    ) -> RecommendationIndex {
        // El catálogo se agrupa una sola vez por proveedor. Antes cada
        // proveedor recorría la lista entera, así que el trabajo crecía con el
        // número de proveedores.
        let byProvider = Dictionary(grouping: models, by: \.provider)

        var recommendations: [ProviderID: [ModelRecommendation]] = [:]
        for provider in ProviderID.allCases {
            guard let providerModels = byProvider[provider], !providerModels.isEmpty else {
                recommendations[provider] = []
                continue
            }
            recommendations[provider] = ModelRecommender.recommendations(
                for: provider,
                providerModels: providerModels,
                now: now
            )
        }
        return RecommendationIndex(byProvider: recommendations)
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
        recommendations(
            for: provider,
            providerModels: models.filter { $0.provider == provider },
            now: now
        )
    }

    /// Variante que recibe ya los modelos de un único proveedor, para no
    /// recorrer el catálogo entero una vez por proveedor.
    public static func recommendations(
        for provider: ProviderID,
        providerModels: [CatalogModel],
        now: Date
    ) -> [ModelRecommendation] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now)
            ?? now.addingTimeInterval(-183 * 86_400)

        let eligible = providerModels.filter { model in
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
        // es la banda premium, pero también con un máximo. Los topes dependen
        // del proveedor: el catálogo de OpenCode Go es mucho más barato que
        // el de Claude o Copilot y necesita bandas propias.
        let caps = WorkloadPriceCaps.caps(for: provider)
        let lightPool = candidates.filter { fits($0.model, .light, caps: caps) }
        let mediumPool = candidates.filter {
            fits($0.model, .medium, caps: caps) && !fits($0.model, .light, caps: caps)
        }
        let ultraPool = candidates.filter {
            fits($0.model, .ultra, caps: caps) && !fits($0.model, .medium, caps: caps)
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
                fits($0.model, badge, caps: caps) && !used.contains($0.model.id)
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

    private static func fits(
        _ model: CatalogModel,
        _ badge: WorkloadBadge,
        caps: [WorkloadBadge: WorkloadPriceCap]
    ) -> Bool {
        guard let input = model.inputPerMillion,
              let output = model.outputPerMillion else {
            return false
        }
        guard let cap = caps[badge] else { return false }
        return input <= cap.maxInputPerMillion
            && output <= cap.maxOutputPerMillion
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
