import Foundation

public enum LiteLLMRenewResult: Sendable {
    case renewed
    case needsLogin
    case offline
}

/// Source of the Google Cloud IAP cookie used by the account portal.
public protocol LiteLLMAuthStore: Sendable {
    func authCookie() async -> String?
    func renew() async -> LiteLLMRenewResult
}

public enum LiteLLMPlatformError: LocalizedError, Sendable {
    case needsLogin
    case network(String)
    case http(Int)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .needsLogin:
            return "La sesión del portal LiteLLM no está activa. Inicia sesión con tu cuenta."
        case .network(let message):
            return "No se pudo conectar con el portal LiteLLM: \(message)"
        case .http(let status):
            return "El portal LiteLLM respondió con HTTP \(status)."
        case .decoding(let message):
            return "Respuesta del portal LiteLLM no reconocida: \(message)"
        }
    }
}

/// Datos personales de uso obtenidos del portal de cuenta LiteLLM.
public struct LiteLLMUsageReport: Sendable {
    public let spend: Double
    public let budget: Double?
    public let budgetDuration: String?
    public let budgetResetAt: Date?
    public let tier: String
    public let accountLabel: String?
    public let daily: [DailyUsage]
    public let models: [ModelUsage]
    public let dataUpdatedAt: Date?

    public init(
        spend: Double,
        budget: Double?,
        budgetDuration: String? = nil,
        budgetResetAt: Date?,
        tier: String,
        accountLabel: String?,
        daily: [DailyUsage],
        models: [ModelUsage],
        dataUpdatedAt: Date?
    ) {
        self.spend = spend
        self.budget = budget
        self.budgetDuration = budgetDuration
        self.budgetResetAt = budgetResetAt
        self.tier = tier
        self.accountLabel = accountLabel
        self.daily = daily
        self.models = models
        self.dataUpdatedAt = dataUpdatedAt
    }

    public var usedPercent: Double {
        guard let budget, budget > 0 else { return 0 }
        return spend / budget * 100
    }
}

/// Read-only account API client. The IAP cookie stays in WebKit and is sent only
/// to the configured account API host.
public final class LiteLLMPlatformClient: @unchecked Sendable {
    public static var baseURL: URL? { EndpointConfiguration.accountAPIBaseURL }
    public static let cookieName = "__Host-GCP_IAP_AUTH_TOKEN_"
    public static let providerName = "litellm"

    private let authStore: any LiteLLMAuthStore
    private let session: URLSession
    private let requestBaseURL: URL?

    public convenience init(authStore: any LiteLLMAuthStore) {
        self.init(
            authStore: authStore,
            configuration: .ephemeral,
            baseURL: Self.baseURL
        )
    }

    init(
        authStore: any LiteLLMAuthStore,
        configuration: URLSessionConfiguration,
        baseURL: URL?
    ) {
        self.authStore = authStore
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.requestBaseURL = baseURL
        session = URLSession(
            configuration: configuration,
            delegate: LiteLLMNoRedirectDelegate(),
            delegateQueue: nil
        )
    }

    /// Fetches personal profile, current-month overview and daily/model
    /// summaries in parallel. Daily history is requested for the last 120 days.
    public func report(days: Int = 120, now: Date = Date()) async throws -> LiteLLMUsageReport {
        let start = DateUtils.dayKey(DateUtils.daysAgo(max(1, days - 1), from: now))
        let end = DateUtils.dayKey(now)

        async let me: LiteLLMMeResponse = get("me")
        async let glance: LiteLLMMonthGlance = get("me/month-glance")
        async let daily: [LiteLLMDailySpend] = get(
            "spend/daily",
            query: ["start": start, "end": end, "provider": Self.providerName]
        )
        async let byModel: [LiteLLMModelSpend] = get(
            "spend/by-model",
            query: ["start": start, "end": end, "provider": Self.providerName]
        )
        async let freshness: LiteLLMFreshness? = try? get("data-freshness", query: ["provider": Self.providerName])

        let (meValue, glanceValue, dailyValue, modelValue, freshnessValue) = try await (
            me, glance, daily, byModel, freshness
        )

        let budget = meValue.budget(for: Self.providerName)
        let currentMonthStart = Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month], from: now)
        ) ?? now
        let glanceIsCurrentMonth = glanceValue.monthStart
            .map { $0 == DateUtils.dayKey(currentMonthStart) } ?? true
        let glanceProvider = glanceIsCurrentMonth ? glanceValue.provider(Self.providerName) : nil
        let spendFromDaily = dailyValue
            .filter { (DateUtils.parseDay($0.day) ?? .distantPast) >= currentMonthStart }
            .reduce(0) { $0 + $1.spend }

        let history = dailyValue.compactMap { row -> DailyUsage? in
            guard let date = DateUtils.parseDay(row.day) else { return nil }
            return DailyUsage(
                date: date,
                provider: .liteLLM,
                tokens: TokenBreakdown(unknown: row.tokens),
                costUSD: row.spend
            )
        }

        let modelHistory = modelValue
            .filter { !$0.model.hasPrefix("mcp:") }
            .map { row in
                ModelUsage(
                    model: row.model,
                    tokens: TokenBreakdown(unknown: row.tokens),
                    costUSD: row.spend
                )
            }
            .sorted { ($0.costUSD ?? 0) > ($1.costUSD ?? 0) }

        return LiteLLMUsageReport(
            spend: glanceProvider?.spendMtd ?? spendFromDaily,
            budget: glanceProvider?.maxBudget ?? budget?.maxBudget,
            budgetDuration: budget?.budgetDuration,
            budgetResetAt: DateUtils.parseLocalDateTime(budget?.budgetResetAt),
            tier: budget?.budgetTeam ?? meValue.teams?.first ?? "LiteLLM",
            accountLabel: meValue.email ?? meValue.name,
            daily: history,
            models: modelHistory,
            dataUpdatedAt: DateUtils.parseISO(freshnessValue?.lastUpdated)
        )
    }

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:],
        mayRenew: Bool = true
    ) async throws -> T {
        guard let cookie = await authStore.authCookie() else {
            guard mayRenew else { throw LiteLLMPlatformError.needsLogin }
            try await renewSession()
            return try await get(path, query: query, mayRenew: false)
        }

        guard let requestBaseURL else {
            throw LiteLLMPlatformError.network("Falta la configuración privada del portal de cuenta.")
        }
        var components = URLComponents(url: requestBaseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
        }
        guard let url = components.url, url.host == requestBaseURL.host else {
            throw LiteLLMPlatformError.network("URL del portal LiteLLM no válida.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch let error as URLError {
            throw LiteLLMPlatformError.network(error.localizedDescription)
        } catch {
            throw LiteLLMPlatformError.network(String(describing: error))
        }

        guard let response = result.1 as? HTTPURLResponse else {
            throw LiteLLMPlatformError.network("Respuesta no HTTP.")
        }

        switch response.statusCode {
        case 200..<300:
            do {
                return try JSONDecoder.liteLLMAPI.decode(T.self, from: result.0)
            } catch {
                throw LiteLLMPlatformError.decoding(String(describing: error))
            }
        case 300..<400, 401:
            guard mayRenew else { throw LiteLLMPlatformError.needsLogin }
            try await renewSession()
            return try await get(path, query: query, mayRenew: false)
        default:
            throw LiteLLMPlatformError.http(response.statusCode)
        }
    }

    private func renewSession() async throws {
        switch await authStore.renew() {
        case .renewed:
            return
        case .needsLogin:
            throw LiteLLMPlatformError.needsLogin
        case .offline:
            throw LiteLLMPlatformError.network("Sin conexión.")
        }
    }
}

private final class LiteLLMNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // IAP usa redirecciones como señal de sesión caducada. No seguirlas:
        // el cookie nunca debe salir del host configurado.
        completionHandler(nil)
    }
}

struct LiteLLMMeResponse: Decodable {
    let email: String?
    let name: String?
    let provider: String?
    let maxBudget: Double?
    let budgetTeam: String?
    let budgetDuration: String?
    let budgetResetAt: String?
    let teams: [String]?
    let budgets: [LiteLLMBudgetResponse]?

    func budget(for provider: String) -> LiteLLMBudgetResponse? {
        if let nested = budgets?.first(where: { $0.provider == provider }) { return nested }
        guard self.provider == provider else { return nil }
        return LiteLLMBudgetResponse(
            provider: provider,
            maxBudget: maxBudget,
            budgetTeam: budgetTeam,
            budgetDuration: budgetDuration,
            budgetResetAt: budgetResetAt
        )
    }
}

struct LiteLLMBudgetResponse: Decodable {
    let provider: String
    let maxBudget: Double?
    let budgetTeam: String?
    let budgetDuration: String?
    let budgetResetAt: String?
}

struct LiteLLMMonthGlance: Decodable {
    let monthStart: String?
    let byProvider: [LiteLLMProviderGlance]?

    func provider(_ name: String) -> LiteLLMProviderGlance? {
        byProvider?.first { $0.provider == name }
    }
}

struct LiteLLMProviderGlance: Decodable {
    let provider: String
    let spendMtd: Double
    let maxBudget: Double?
    let projection: Double?
}

struct LiteLLMDailySpend: Decodable {
    let day: String
    let spend: Double
    let requests: Int
    let tokens: Int
}

struct LiteLLMModelSpend: Decodable {
    let model: String
    let spend: Double
    let requests: Int
    let tokens: Int
}

struct LiteLLMFreshness: Decodable {
    let lastUpdated: String?
}

extension JSONDecoder {
    static var liteLLMAPI: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
