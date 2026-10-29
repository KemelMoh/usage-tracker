import Foundation

// MARK: - Catálogo de modelos

public struct CatalogModel: Codable, Identifiable, Hashable, Sendable {
    public var modelID: String
    public var name: String
    public var provider: ProviderID
    public var inputPerMillion: Double?
    public var outputPerMillion: Double?
    public var cacheReadPerMillion: Double?
    public var cacheWritePerMillion: Double?
    public var contextWindow: Int?
    public var maxOutput: Int?
    public var reasoning: Bool
    public var toolCall: Bool
    /// El modelo aparece en el listado en vivo del proveedor (OpenCode Go).
    public var isLive: Bool
    /// Fecha de publicación en formato yyyy-MM-dd, si models.dev la conoce.
    public var releaseDate: String?
    public var lastUpdated: String?
    /// Estado de models.dev, por ejemplo "deprecated".
    public var status: String?
    /// Identificador canónico para reconocer variantes del mismo modelo.
    public var canonicalModelID: String?

    public var id: String { "\(provider.rawValue)/\(modelID)" }

    public var hasPublishedPrice: Bool {
        inputPerMillion != nil || outputPerMillion != nil
    }

    public var isDeprecated: Bool {
        status?.caseInsensitiveCompare("deprecated") == .orderedSame
    }

    /// Fecha de referencia para la recomendación: publicación o última actualización.
    public var referenceDate: Date? {
        DateUtils.parseDay(releaseDate) ?? DateUtils.parseDay(lastUpdated)
    }

    /// Modelo con tarifa publicada de 0 USD por millón de tokens.
    public var isFree: Bool {
        guard let inputPerMillion, let outputPerMillion,
              inputPerMillion == 0, outputPerMillion == 0 else {
            return false
        }
        if let cacheReadPerMillion, cacheReadPerMillion != 0 { return false }
        if let cacheWritePerMillion, cacheWritePerMillion != 0 { return false }
        return true
    }

    public init(
        modelID: String,
        name: String,
        provider: ProviderID,
        inputPerMillion: Double? = nil,
        outputPerMillion: Double? = nil,
        cacheReadPerMillion: Double? = nil,
        cacheWritePerMillion: Double? = nil,
        contextWindow: Int? = nil,
        maxOutput: Int? = nil,
        reasoning: Bool = false,
        toolCall: Bool = false,
        isLive: Bool = false,
        releaseDate: String? = nil,
        lastUpdated: String? = nil,
        status: String? = nil,
        canonicalModelID: String? = nil
    ) {
        self.modelID = modelID
        self.name = name
        self.provider = provider
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.contextWindow = contextWindow
        self.maxOutput = maxOutput
        self.reasoning = reasoning
        self.toolCall = toolCall
        self.isLive = isLive
        self.releaseDate = releaseDate
        self.lastUpdated = lastUpdated
        self.status = status
        self.canonicalModelID = canonicalModelID
    }
}

public struct ModelCatalog: Codable, Sendable {
    public var fetchedAt: Date
    public var models: [CatalogModel]

    public init(fetchedAt: Date = Date(), models: [CatalogModel] = []) {
        self.fetchedAt = fetchedAt
        self.models = models
    }

    public var isEmpty: Bool { models.isEmpty }

    public func models(for provider: ProviderID) -> [CatalogModel] {
        models.filter { $0.provider == provider }
    }

    /// Tabla de precios por modelo para estimar costes con datos actuales.
    public func priceTable(for provider: ProviderID) -> [ModelPrice] {
        var prices: [ModelPrice] = models(for: provider).compactMap { model in
            guard let input = model.inputPerMillion,
                  let output = model.outputPerMillion else {
                return nil
            }
            return ModelPrice(
                pattern: model.modelID.lowercased(),
                input: input,
                output: output,
                cacheRead: model.cacheReadPerMillion ?? input,
                cacheWrite: model.cacheWritePerMillion ?? input
            )
        }
        prices.append(contentsOf: PricingCatalog.defaultPrices)
        return prices
    }
}

// MARK: - models.dev

public enum ModelsDevParser {
    static let providerMap: [String: ProviderID] = [
        "opencode-go": .opencodeGo,
        "github-copilot": .copilot,
        "anthropic": .claude
    ]

    public static func parse(data: Data) throws -> [CatalogModel] {
        do {
            let envelope = try JSONDecoder().decode(ProviderEnvelope.self, from: data)
            var models: [CatalogModel] = []

            for (providerKey, provider) in envelope.providers {
                guard let providerID = providerMap[providerKey] else { continue }
                for (key, model) in provider.models {
                    let modelID = model.id ?? key
                    models.append(
                        CatalogModel(
                            modelID: modelID,
                            name: model.name ?? modelID,
                            provider: providerID,
                            inputPerMillion: model.cost?.input,
                            outputPerMillion: model.cost?.output,
                            cacheReadPerMillion: model.cost?.cache_read,
                            cacheWritePerMillion: model.cost?.cache_write,
                            contextWindow: model.limit?.context,
                            maxOutput: model.limit?.output,
                            reasoning: model.reasoning ?? false,
                            toolCall: model.tool_call ?? false,
                            releaseDate: model.release_date,
                            lastUpdated: model.last_updated,
                            status: model.status,
                            canonicalModelID: model.canonical_model_id
                        )
                    )
                }
            }

            return ModelCatalogService.sorted(models)
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.decoding(error.localizedDescription)
        }
    }

    private struct DynamicCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct ProviderEnvelope: Decodable {
        let providers: [String: ProviderPayload]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: DynamicCodingKey.self)
            var providers: [String: ProviderPayload] = [:]
            for key in container.allKeys {
                guard ModelsDevParser.providerMap[key.stringValue] != nil else { continue }
                providers[key.stringValue] = try container.decode(ProviderPayload.self, forKey: key)
            }
            self.providers = providers
        }
    }

    private struct ProviderPayload: Decodable {
        let models: [String: ModelPayload]
    }

    private struct ModelPayload: Decodable {
        let id: String?
        let name: String?
        let cost: Cost?
        let limit: Limit?
        let reasoning: Bool?
        let tool_call: Bool?
        let release_date: String?
        let last_updated: String?
        let status: String?
        let canonical_model_id: String?
    }

    private struct Cost: Decodable {
        let input: Double?
        let output: Double?
        let cache_read: Double?
        let cache_write: Double?
    }

    private struct Limit: Decodable {
        let context: Int?
        let output: Int?
    }
}

public enum ModelsDevClient {
    public static let endpoint = URL(string: "https://models.dev/api.json?type=all")!

    public static func fetchModels() async throws -> [CatalogModel] {
        let (data, _) = try await HTTPClient.shared.get(
            url: endpoint,
            headers: [
                "Accept": "application/json",
                "User-Agent": "UsageTracker/0.2"
            ]
        )
        return try ModelsDevParser.parse(data: data)
    }
}

// MARK: - Combinación con el listado en vivo

public enum ModelCatalogService {
    /// Clave de ordenación precalculada para el catálogo.
    private struct SortKey {
        /// Nombre normalizado: minúsculas y sin acentos, para que la
        /// comparación sea determinista y barata.
        let normalized: String
        let modelID: String
        let model: CatalogModel
    }

    /// Normaliza un nombre para ordenarlo sin depender de la colación ICU.
    public static func normalizedName(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
    }

    /// Comparación en orden natural: los bloques de dígitos se comparan por
    /// valor, no lexicográficamente, para que "Model 2" vaya antes que
    /// "Model 10". Es el comportamiento de `localizedStandardCompare`, pero
    /// sin el coste de la colación ICU.
    ///
    /// Se comparan los nombres normalizados carácter a carácter. Cuando ambos
    /// son dígitos, se lee el número completo de cada lado y se comparan como
    /// enteros.
    public static func naturalLessThan(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs)
        let right = Array(rhs)
        var i = 0
        var j = 0

        while i < left.count, j < right.count {
            let a = left[i]
            let b = right[j]

            if a.isNumber, b.isNumber {
                var endA = i
                var numberA = 0
                while endA < left.count, let digit = left[endA].wholeNumberValue {
                    numberA = numberA * 10 + digit
                    endA += 1
                }
                var endB = j
                var numberB = 0
                while endB < right.count, let digit = right[endB].wholeNumberValue {
                    numberB = numberB * 10 + digit
                    endB += 1
                }

                if numberA != numberB { return numberA < numberB }

                // A igualdad numérica se compara el número de dígitos, para
                // que "007" quede antes que "7".
                if endA - i != endB - j { return endA - i < endB - j }

                i = endA
                j = endB
                continue
            }

            if a != b { return a < b }
            i += 1
            j += 1
        }

        if left.count - i != right.count - j { return left.count - i < right.count - j }
        return false
    }

    public static func fetch() async throws -> ModelCatalog {
        async let devTask = ModelsDevClient.fetchModels()
        async let liveTask = OpenCodeModelsClient().fetchIDs()

        let devModels = (try? await devTask) ?? []
        let liveIDs = (try? await liveTask) ?? []

        // models.dev es la fuente principal: sin ella no habría precios ni
        // modelos de Claude/Copilot, así que se conserva el catálogo anterior.
        guard !devModels.isEmpty else {
            throw ProviderError.network("No se pudo cargar el catálogo de precios de models.dev.")
        }

        return makeCatalog(devModels: devModels, openCodeLiveIDs: liveIDs)
    }

    /// Usa el catálogo de models.dev como fuente de precios y el listado en vivo
    /// de OpenCode Go como fuente de disponibilidad.
    public static func makeCatalog(
        devModels: [CatalogModel],
        openCodeLiveIDs: [String]
    ) -> ModelCatalog {
        var result: [CatalogModel] = []

        let openCodeDev = devModels.filter { $0.provider == .opencodeGo }
        let liveIDs = openCodeLiveIDs.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if liveIDs.isEmpty {
            result.append(contentsOf: openCodeDev)
        } else {
            let byID = Dictionary(uniqueKeysWithValues: openCodeDev.map { ($0.modelID, $0) })
            var seen: Set<String> = []
            for modelID in liveIDs where seen.insert(modelID).inserted {
                if var entry = byID[modelID] {
                    entry.isLive = true
                    result.append(entry)
                } else {
                    result.append(
                        CatalogModel(
                            modelID: modelID,
                            name: displayName(for: modelID),
                            provider: .opencodeGo,
                            isLive: true
                        )
                    )
                }
            }

            // Los modelos gratuitos de models.dev también se muestran aunque el
            // listado en vivo de OpenCode todavía no los incluya.
            for entry in openCodeDev where !seen.contains(entry.modelID) && entry.isFree {
                result.append(entry)
            }
        }

        result.append(contentsOf: devModels.filter { $0.provider != .opencodeGo })
        return ModelCatalog(models: sorted(result))
    }

    public static func sorted(_ models: [CatalogModel]) -> [CatalogModel] {
        // `localizedStandardCompare` prepara una colación ICU en cada llamada y el
        // ordenador la invoca O(n log n) veces. Se agrupa primero por
        // proveedor y, dentro de cada grupo, se ordenan las claves de
        // comparación precalculadas con `compareOptions`, de modo que la
        // colación se resuelve una vez por entrada y no una por comparación.
        let byProvider = Dictionary(grouping: models, by: \.provider)

        var result: [CatalogModel] = []
        result.reserveCapacity(models.count)

        for provider in ProviderID.allCases {
            guard let entries = byProvider[provider] else { continue }
            let keyed: [SortKey] = entries.map {
                SortKey(
                    normalized: normalizedName($0.name),
                    modelID: $0.modelID,
                    model: $0
                )
            }
            result.append(contentsOf: keyed.sorted { lhs, rhs in
                if lhs.normalized != rhs.normalized {
                    return naturalLessThan(lhs.normalized, rhs.normalized)
                }
                return lhs.modelID < rhs.modelID
            }.map(\.model))
        }

        // Proveedores desconocidos al final, conservando su orden de entrada.
        let known = Set(ProviderID.allCases)
        for (provider, entries) in byProvider where !known.contains(provider) {
            result.append(contentsOf: entries)
        }

        return result
    }

    static func displayName(for modelID: String) -> String {
        let brands: [String: String] = [
            "gpt": "GPT",
            "glm": "GLM",
            "qwen": "Qwen",
            "kimi": "Kimi",
            "deepseek": "DeepSeek",
            "mimo": "MiMo",
            "minimax": "MiniMax",
            "grok": "Grok",
            "claude": "Claude",
            "gemini": "Gemini",
            "mai": "MAI",
            "longcat": "LongCat",
            "muse": "Muse",
            "omen": "Omen",
            "hy": "HY"
        ]

        return modelID
            .split(separator: "-")
            .map { part -> String in
                let word = String(part)
                let lower = word.lowercased()
                if let brand = brands[lower] { return brand }
                guard let first = word.first else { return word }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
