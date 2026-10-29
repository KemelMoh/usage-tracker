import Foundation

public struct ModelPrice: Codable, Hashable, Sendable {
    public var pattern: String
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double

    public init(
        pattern: String,
        input: Double,
        output: Double,
        cacheRead: Double,
        cacheWrite: Double
    ) {
        self.pattern = pattern
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }
}

public enum PricingCatalog {
    /// Precios públicos de referencia en USD por 1M de tokens.
    /// Se usan como respaldo cuando el catálogo dinámico no tiene el modelo.
    public static let defaultPrices: [ModelPrice] = [
        ModelPrice(pattern: "claude-opus", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        ModelPrice(pattern: "claude-sonnet", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        ModelPrice(pattern: "claude-haiku", input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25),
        ModelPrice(pattern: "default", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)
    ]

    /// Elige el patrón más específico que aparezca en el nombre del modelo.
    /// `catalog` puede venir de models.dev; los precios de respaldo se añaden
    /// para que un modelo desconocido siga teniendo una estimación razonable.
    public static func price(for model: String, catalog: [ModelPrice]? = nil) -> ModelPrice {
        let normalized = model.lowercased()
        let candidates = (catalog ?? []) + defaultPrices
        let matches = candidates.filter {
            $0.pattern != "default" && normalized.contains($0.pattern.lowercased())
        }
        if let best = matches.max(by: { $0.pattern.count < $1.pattern.count }) {
            return best
        }
        return defaultPrices.first(where: { $0.pattern == "default" })!
    }

    public static func cost(
        model: String,
        tokens: TokenBreakdown,
        catalog: [ModelPrice]? = nil
    ) -> Double {
        let price = price(for: model, catalog: catalog)
        let inputCost = Double(tokens.input) * price.input / 1_000_000
        let outputCost = Double(tokens.output) * price.output / 1_000_000
        let cacheReadCost = Double(tokens.cacheRead) * price.cacheRead / 1_000_000
        let cacheWriteCost = Double(tokens.cacheWrite) * price.cacheWrite / 1_000_000
        let unknownCost = Double(tokens.unknown) * price.input / 1_000_000
        return inputCost + outputCost + cacheReadCost + cacheWriteCost + unknownCost
    }

    public static func blendedRate(
        model: String,
        tokens: TokenBreakdown,
        catalog: [ModelPrice]? = nil
    ) -> Double {
        let total = tokens.total
        guard total > 0 else {
            return price(for: model, catalog: catalog).input / 1_000_000
        }
        return cost(model: model, tokens: tokens, catalog: catalog) / Double(total)
    }

    public static let copilotOveragePerRequestUSD = 0.04
}
