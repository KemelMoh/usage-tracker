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

    /// Resolutor de precios con memoria para el modelo.
    ///
    /// `price(for:catalog:)` concatena arrays y filtra en cada llamada. Al
    /// recorrer el historial se llama miles de veces con los mismos nombres de
    /// modelo, así que aquí se resuelve una vez por modelo y se reutiliza.
    public final class Resolver: @unchecked Sendable {
        private let catalog: [ModelPrice]
        private let defaultPrice: ModelPrice
        private var cache: [String: ModelPrice] = [:]
        private let lock = NSLock()

        public init(catalog: [ModelPrice]? = nil) {
            let resolved = catalog ?? []
            // Los patrones se guardan ya en minúsculas y sin el patrón
            // "default", que solo actúa como respaldo.
            self.catalog = resolved
                .filter { $0.pattern.lowercased() != "default" }
                .map {
                    ModelPrice(
                        pattern: $0.pattern.lowercased(),
                        input: $0.input,
                        output: $0.output,
                        cacheRead: $0.cacheRead,
                        cacheWrite: $0.cacheWrite
                    )
                }
            self.defaultPrice = PricingCatalog.defaultPrices
                .first(where: { $0.pattern == "default" })!
        }

        /// Precio del modelo. El resultado se memoriza por nombre.
        public func price(for model: String) -> ModelPrice {
            let key = model.lowercased()
            lock.lock()
            if let cached = cache[key] {
                lock.unlock()
                return cached
            }
            lock.unlock()

            var best: ModelPrice?
            var bestLength = 0
            for candidate in catalog where key.contains(candidate.pattern) {
                if candidate.pattern.count > bestLength {
                    best = candidate
                    bestLength = candidate.pattern.count
                }
            }

            let resolved = best ?? defaultPrice
            lock.lock()
            cache[key] = resolved
            lock.unlock()
            return resolved
        }

        public func cost(model: String, tokens: TokenBreakdown) -> Double {
            let price = price(for: model)
            let inputCost = Double(tokens.input) * price.input / 1_000_000
            let outputCost = Double(tokens.output) * price.output / 1_000_000
            let cacheReadCost = Double(tokens.cacheRead) * price.cacheRead / 1_000_000
            let cacheWriteCost = Double(tokens.cacheWrite) * price.cacheWrite / 1_000_000
            let unknownCost = Double(tokens.unknown) * price.input / 1_000_000
            return inputCost + outputCost + cacheReadCost + cacheWriteCost + unknownCost
        }
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
