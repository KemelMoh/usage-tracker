import Foundation

/// Builds the LiteLLM model list from LiteLLM's public cost map.
///
/// The authenticated `/v1/models` endpoint is useful when the budget is active,
/// but the proxy rejects it with the same 422 as inference after a budget is
/// exceeded. The public cost map contains the proxy's deployment entries and
/// remains available in either case.
public enum LiteLLMModelsClient {
    public static func fetchModels() async throws -> [CatalogModel] {
        guard let baseURL = EndpointConfiguration.liteLLMProxyBaseURL else {
            throw ProviderError.network("Falta la configuración privada del endpoint LiteLLM.")
        }
        let (data, _) = try await HTTPClient.shared.get(
            url: baseURL.appendingPathComponent("public/litellm_model_cost_map"),
            headers: [
                "Accept": "application/json",
                "User-Agent": "UsageTracker/0.2"
            ]
        )
        return try parseCostMap(data: data)
    }

    /// Parses only the proxy's own deployment rows, identified by `base_model`.
    /// Standard LiteLLM pricing rows are intentionally ignored.
    public static func parseCostMap(data: Data) throws -> [CatalogModel] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.decoding("El mapa de precios de LiteLLM no es un objeto JSON.")
        }

        var deployments: [String: [Deployment]] = [:]
        var listPrices: [String: ListPrice] = [:]
        for (deploymentID, raw) in root {
            guard let value = raw as? [String: Any] else { continue }
            if value["base_model"] == nil,
               let input = number(value["input_cost_per_token"]),
               let output = number(value["output_cost_per_token"]) {
                listPrices[deploymentID.lowercased()] = ListPrice(
                    input: input,
                    output: output,
                    cacheRead: number(value["cache_read_input_token_cost"]),
                    cacheWrite: number(value["cache_creation_input_token_cost"]),
                    maxInput: integer(value["max_input_tokens"]),
                    maxOutput: integer(value["max_output_tokens"])
                )
            }
            guard let base = value["base_model"] as? String else { continue }
            let normalizedBase = base.replacingOccurrences(of: "@", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedBase.isEmpty else { continue }

            deployments[normalizedBase, default: []].append(
                Deployment(
                    id: deploymentID,
                    tier: value["tier"] as? String,
                    input: number(value["input_cost_per_token"]),
                    output: number(value["output_cost_per_token"]),
                    cacheRead: number(value["cache_read_input_token_cost"]),
                    cacheWrite: number(value["cache_creation_input_token_cost"]),
                    maxInput: integer(value["max_input_tokens"]),
                    maxOutput: integer(value["max_output_tokens"])
                )
            )
        }

        var models: [CatalogModel] = []
        for baseModel in deployments.keys.sorted() {
            guard let rows = deployments[baseModel]?.sorted(by: deploymentOrder), !rows.isEmpty else { continue }
            let hasFreeAndPaidClaudeRoutes = baseModel.lowercased().hasPrefix("claude-")
                && rows.contains { $0.tier == "free" }
                && rows.contains { $0.tier == "paid" }

            let selected: [Deployment]
            if hasFreeAndPaidClaudeRoutes {
                // LiteLLM exposes Claude's paid Vertex route under a `-vertex` id.
                var byTier: [String: Deployment] = [:]
                for row in rows {
                    guard let tier = row.tier else { continue }
                    if byTier[tier] == nil { byTier[tier] = row }
                }
                selected = [byTier["free"], byTier["paid"]].compactMap { $0 }
            } else {
                // A model can have duplicate deployment IDs in the public map.
                // Pick one deterministic row, preferring the paid route if present.
                selected = [rows.first(where: { $0.tier == "paid" }) ?? rows[0]]
            }

            for row in selected {
                let isVertexRoute = hasFreeAndPaidClaudeRoutes && row.tier == "paid"
                let modelID = baseModel + (isVertexRoute ? "-vertex" : "")
                let displayID = isVertexRoute ? String(modelID.dropLast("-vertex".count)) : modelID
                let shortName = displayID.split(separator: "/").last.map(String.init) ?? displayID
                let baseName = ModelCatalogService.displayName(for: shortName)
                let displayName = isVertexRoute ? "\(baseName) (Vertex)" : baseName
                let listPrice = listPrice(for: modelID, in: listPrices)
                models.append(
                    CatalogModel(
                        modelID: modelID,
                        name: displayName,
                        provider: .liteLLM,
                        inputPerMillion: perMillion(row.input),
                        outputPerMillion: perMillion(row.output),
                        cacheReadPerMillion: perMillion(row.cacheRead),
                        cacheWritePerMillion: perMillion(row.cacheWrite),
                        listInputPerMillion: perMillion(listPrice?.input),
                        listOutputPerMillion: perMillion(listPrice?.output),
                        contextWindow: row.maxInput ?? listPrice?.maxInput,
                        maxOutput: row.maxOutput ?? listPrice?.maxOutput,
                        isLive: true
                    )
                )
            }
        }

        guard !models.isEmpty else {
            throw ProviderError.decoding("El mapa de precios no contiene deployments de LiteLLM.")
        }
        return ModelCatalogService.sorted(models)
    }

    private struct Deployment {
        let id: String
        let tier: String?
        let input: Double?
        let output: Double?
        let cacheRead: Double?
        let cacheWrite: Double?
        let maxInput: Int?
        let maxOutput: Int?
    }

    private struct ListPrice {
        let input: Double
        let output: Double
        let cacheRead: Double?
        let cacheWrite: Double?
        let maxInput: Int?
        let maxOutput: Int?
    }

    private static func deploymentOrder(_ lhs: Deployment, _ rhs: Deployment) -> Bool {
        let tierRank: (String?) -> Int = { tier in
            switch tier {
            case "free": return 0
            case "paid": return 1
            default: return 2
            }
        }
        if tierRank(lhs.tier) != tierRank(rhs.tier) {
            return tierRank(lhs.tier) < tierRank(rhs.tier)
        }
        return lhs.id < rhs.id
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func listPrice(for modelID: String, in prices: [String: ListPrice]) -> ListPrice? {
        let base = modelID.hasSuffix("-vertex")
            ? String(modelID.dropLast("-vertex".count))
            : modelID
        let short = base.split(separator: "/").last.map(String.init) ?? base
        let keys = [
            modelID,
            base,
            short,
            "anthropic/\(short)",
            "anthropic.\(short)",
            "vertex_ai/\(short)",
            "gemini/\(short)",
            "openai/\(short)",
            "google/\(short)",
            "mistral/\(short)",
            "deepseek/\(short)"
        ]
        return keys.lazy.compactMap { prices[$0.lowercased()] }.first
    }

    private static func perMillion(_ value: Double?) -> Double? {
        value.map { $0 * 1_000_000 }
    }
}
