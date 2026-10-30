import Foundation

// MARK: - LiteLLM

/// Cliente de uso para el proxy LiteLLM.
///
/// El proxy comprueba el presupuesto antes de resolver la ruta. Cuando está
/// agotado responde 422 a cualquier endpoint e incluye en el mensaje el
/// consumo y el límite. Ese 422 describe justo el estado que el usuario quiere
/// ver, así que se interpreta como un resultado válido y no como un fallo.
public struct LiteLLMClient: Sendable {
    public init() {}

    public func fetch(apiKey: String?, fallbackPlan: String) async -> ProviderSnapshot {
        guard let apiKey, !apiKey.isEmpty else {
            return .failure(
                provider: .liteLLM,
                planName: fallbackPlan,
                error: ProviderError.missingCredential(
                    "No se encontró la clave del proxy de LiteLLM. Instala Claude Usage Tracker o pega la clave en Ajustes."
                )
            )
        }
        guard !apiKey.hasPrefix("sk-ant-") else {
            return .failure(
                provider: .liteLLM,
                planName: fallbackPlan,
                error: ProviderError.missingCredential(
                    "Parece una clave directa de Anthropic, no una clave del proxy LiteLLM."
                )
            )
        }
        guard let baseURL = EndpointConfiguration.liteLLMProxyBaseURL else {
            return .failure(
                provider: .liteLLM,
                planName: fallbackPlan,
                error: ProviderError.network("Falta la configuración privada del endpoint LiteLLM.")
            )
        }

        do {
            let (data, response) = try await HTTPClient.shared.perform(
                url: baseURL.appendingPathComponent("key/info"),
                headers: Self.headers(apiKey: apiKey)
            )

            switch response.statusCode {
            case 200..<300:
                return await snapshot(fromKeyInfo: data, apiKey: apiKey, baseURL: baseURL, planName: fallbackPlan)
            case 422:
                guard let budget = LiteLLMBudget(exceededPayload: data) else {
                    throw ProviderError.decoding("El proxy no devolvió los datos del presupuesto.")
                }
                return snapshot(from: budget, planName: fallbackPlan)
            case 401, 403:
                throw ProviderError.auth(
                    "La clave del proxy de LiteLLM no es válida o ha caducado."
                )
            default:
                throw ProviderError.http(response.statusCode, "Respuesta del proxy no reconocida.")
            }
        } catch let error as ProviderError {
            if case .auth = error {
                return .failure(
                    provider: .liteLLM,
                    planName: fallbackPlan,
                    error: ProviderError.auth(
                        "La clave del proxy de LiteLLM no es válida o ha caducado."
                    )
                )
            }
            return .failure(provider: .liteLLM, planName: fallbackPlan, error: error)
        } catch {
            return .failure(provider: .liteLLM, planName: fallbackPlan, error: error)
        }
    }

    // MARK: - Datos

    /// Lee `GET /key/info`. Cuando la clave no tiene límite propio, el
    /// presupuesto que manda es el del usuario y se consulta `GET /user/info`.
    private func snapshot(
        fromKeyInfo data: Data,
        apiKey: String,
        baseURL: URL,
        planName: String
    ) async -> ProviderSnapshot {
        guard let info = LiteLLMKeyInfo(payload: data) else {
            return .failure(
                provider: .liteLLM,
                planName: planName,
                error: ProviderError.decoding("La respuesta del proxy no se pudo leer.")
            )
        }

        var budget = LiteLLMBudget(
            spend: info.spend ?? 0,
            limit: info.maxBudget,
            resetsAt: info.budgetResetAt,
            account: info.keyAlias
        )

        if budget.limit == nil, let user = await fetchUserInfo(apiKey: apiKey, baseURL: baseURL) {
            budget.spend = user.spend ?? budget.spend
            budget.limit = user.maxBudget
            budget.resetsAt = user.budgetResetAt ?? budget.resetsAt
            budget.account = user.keyAlias ?? budget.account
        }

        return snapshot(from: budget, planName: planName)
    }

    /// `GET /user/info` con la misma clave. Solo se usa como respaldo, así que
    /// cualquier error se ignora y se conserva lo que ya se sabe.
    private func fetchUserInfo(apiKey: String, baseURL: URL) async -> LiteLLMKeyInfo? {
        do {
            let (data, response) = try await HTTPClient.shared.perform(
                url: baseURL.appendingPathComponent("user/info"),
                headers: Self.headers(apiKey: apiKey)
            )
            guard (200..<300).contains(response.statusCode) else { return nil }
            return LiteLLMKeyInfo(payload: data)
        } catch {
            return nil
        }
    }

    private func snapshot(from budget: LiteLLMBudget, planName: String) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: .liteLLM,
            planName: planName,
            status: .ok,
            windows: [window(from: budget)],
            accountLabel: budget.account
        )
    }

    private func window(from budget: LiteLLMBudget) -> QuotaWindow {
        let hasLimit = (budget.limit ?? 0) > 0
        let percent = hasLimit ? budget.spend / (budget.limit ?? 1) * 100 : 0
        let detail: String
        if hasLimit {
            detail = "\(NumberFormat.usd(budget.spend)) de \(NumberFormat.usd(budget.limit ?? 0))"
        } else {
            detail = "\(NumberFormat.usd(budget.spend)) consumidos"
        }

        return QuotaWindow(
            id: "budget",
            label: "Presupuesto",
            usedPercent: percent,
            resetsAt: budget.resetsAt,
            windowDuration: 30 * 86_400,
            detail: detail,
            isUnlimited: !hasLimit,
            usedValue: budget.spend,
            limitValue: budget.limit
        )
    }

    private static func headers(apiKey: String) -> [String: String] {
        [
            "Authorization": "Bearer \(apiKey)",
            "Accept": "application/json",
            "User-Agent": "UsageTracker/0.1"
        ]
    }
}

// MARK: - Respuestas

/// Consumo y límite del presupuesto del proxy.
public struct LiteLLMBudget: Equatable, Sendable {
    public var spend: Double
    public var limit: Double?
    public var resetsAt: Date?
    public var account: String?

    public init(spend: Double, limit: Double?, resetsAt: Date?, account: String?) {
        self.spend = spend
        self.limit = limit
        self.resetsAt = resetsAt
        self.account = account
    }

    /// Lee el cuerpo 422 que devuelve LiteLLM al exceder el presupuesto:
    /// `Budget has been exceeded! TeamMember=usuario:equipo Current cost: 105.23, Max budget: 105.0`.
    public init?(exceededPayload data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = root["error"] as? [String: Any],
              let message = error["message"] as? String else {
            return nil
        }

        let pattern = #"Current cost:\s*([0-9]+(?:\.[0-9]+)?),\s*Max budget:\s*([0-9]+(?:\.[0-9]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
              ),
              match.numberOfRanges >= 3 else {
            return nil
        }

        func number(_ index: Int) -> Double? {
            guard let range = Range(match.range(at: index), in: message) else { return nil }
            return Double(message[range])
        }

        guard let spend = number(1), let limit = number(2) else { return nil }

        self.spend = spend
        self.limit = limit
        self.resetsAt = nil
        self.account = Self.account(from: message)
    }

    /// El identificador del miembro del equipo es `correo:uuid`. Solo se
    /// conserva el correo, que es lo que identifica la cuenta.
    private static func account(from message: String) -> String? {
        let pattern = #"TeamMember=([^:\s]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)
              ),
              let range = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[range])
    }
}

/// Datos de la clave o del usuario según la forma de la respuesta del proxy.
public struct LiteLLMKeyInfo: Equatable, Sendable {
    public let spend: Double?
    public let maxBudget: Double?
    public let budgetResetAt: Date?
    public let keyAlias: String?

    public init(spend: Double?, maxBudget: Double?, budgetResetAt: Date?, keyAlias: String?) {
        self.spend = spend
        self.maxBudget = maxBudget
        self.budgetResetAt = budgetResetAt
        self.keyAlias = keyAlias
    }

    public init?(payload data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // `/key/info` envuelve la fila en "info"; `/user/info` la devuelve plana.
        let info = root["info"] as? [String: Any] ?? root

        spend = info.number("spend")
        maxBudget = info.number("max_budget", "maxBudget")
        budgetResetAt = DateUtils.parseISO(info.string("budget_reset_at", "budgetResetAt"))
        keyAlias = info.string("key_alias", "keyAlias")
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// Busca el primer valor presente entre las claves dadas. Se aceptan las
    /// dos grafías porque el proxy puede devolver `max_budget` o `maxBudget`.
    func number(_ keys: String...) -> Double? {
        for key in keys {
            if let value = self[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }

    func string(_ keys: String...) -> String? {
        for key in keys {
            if let value = self[key] as? String { return value }
        }
        return nil
    }
}
