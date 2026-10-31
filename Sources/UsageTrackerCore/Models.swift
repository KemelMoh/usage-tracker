import Foundation

// MARK: - Providers

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Old on-disk ID kept only to migrate existing local state and Keychain entries.
    public static let legacyLiteLLMIdentifier = ["mas", "orange"].joined()

    case copilot = "copilot"
    case claude = "claude"
    case opencodeGo = "opencode-go"
    case liteLLM = "litellm"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .opencodeGo: return "OpenCode Go"
        case .copilot: return "GitHub Copilot"
        case .claude: return "Anthropic"
        case .liteLLM: return "LiteLLM"
        }
    }

    public var shortName: String {
        switch self {
        case .opencodeGo: return "OC"
        case .copilot: return "CP"
        case .claude: return "AN"
        case .liteLLM: return "LLM"
        }
    }

    public var defaultPlanName: String {
        switch self {
        case .opencodeGo: return "Go"
        case .copilot: return "Business"
        case .claude: return "Pro"
        case .liteLLM: return "LiteLLM"
        }
    }

    public var defaultMonthlyPriceUSD: Double {
        switch self {
        case .opencodeGo: return 10
        case .copilot: return 19
        case .claude: return 20
        // El presupuesto lo concede la empresa: no es un gasto del usuario.
        case .liteLLM: return 0
        }
    }

    public var accentHex: String {
        switch self {
        case .opencodeGo: return "#F97316"
        case .copilot: return "#6D5EF8"
        case .claude: return "#D97757"
        case .liteLLM: return "#635BFF"
        }
    }

    public var symbolName: String {
        switch self {
        case .opencodeGo: return "chevron.left.forwardslash.chevron.right"
        case .copilot: return "bolt.fill"
        case .claude: return "sparkles"
        case .liteLLM: return "server.rack"
        }
    }

    public var planOptions: [PlanOption] {
        switch self {
        case .opencodeGo:
            return [
                PlanOption(name: "Go", priceUSD: 10),
                PlanOption(name: "Go Plus", priceUSD: 40)
            ]
        case .copilot:
            return [
                PlanOption(name: "Free", priceUSD: 0),
                PlanOption(name: "Pro", priceUSD: 10),
                PlanOption(name: "Pro+", priceUSD: 39),
                PlanOption(
                    name: "Business",
                    priceUSD: 19,
                    kind: .perSeat,
                    note: "Precio por asiento. Puede estar pagado por la organización."
                ),
                PlanOption(
                    name: "Enterprise",
                    priceUSD: 39,
                    kind: .perSeat,
                    note: "Precio por asiento. Puede estar pagado por la organización."
                )
            ]
        case .claude:
            return [
                PlanOption(name: "Free", priceUSD: 0),
                PlanOption(name: "Pro", priceUSD: 20),
                PlanOption(name: "Max 5x", priceUSD: 100),
                PlanOption(name: "Max 20x", priceUSD: 200),
                PlanOption(
                    name: "Team",
                    priceUSD: 30,
                    kind: .perSeat,
                    note: "Precio por asiento. Puede estar pagado por la organización."
                ),
                PlanOption(
                    name: "Enterprise",
                    priceUSD: 0,
                    kind: .included,
                    note: "Precio personalizado o incluido por la organización."
                )
            ]
        case .liteLLM:
            return [
                PlanOption(name: "Iron", priceUSD: 0, kind: .included),
                PlanOption(name: "Bronze", priceUSD: 0, kind: .included),
                PlanOption(name: "Silver", priceUSD: 0, kind: .included),
                PlanOption(name: "Gold", priceUSD: 0, kind: .included),
                PlanOption(
                    name: "LiteLLM",
                    priceUSD: 0,
                    kind: .included,
                    note: "Presupuesto incluido, no es un gasto propio."
                )
            ]
        }
    }

    /// Proveedores cuyo plan se puede inferir de la sesión o de la API.
    /// OpenCode Go solo devuelve porcentajes de uso, no el plan contratado.
    public var supportsPlanDetection: Bool {
        switch self {
        case .opencodeGo: return false
        case .copilot, .claude: return true
        case .liteLLM: return true
        }
    }

    public var planDetectionNote: String? {
        switch self {
        case .opencodeGo:
            return "OpenCode Go no expone el plan en su API; se asume Go. Elige Go Plus si lo tienes."
        case .copilot:
            return "El plan se detecta desde tu cuenta de GitHub."
        case .claude:
            return "El plan se detecta desde la sesión de Claude Code."
        case .liteLLM:
            return "El nivel del presupuesto se detecta con la sesión del portal de cuenta LiteLLM."
        }
    }

    public func planOption(named name: String) -> PlanOption? {
        planOptions.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public var credentialHint: String {
        switch self {
        case .opencodeGo:
            return "Se detecta en ~/.local/share/opencode/auth.json o puedes pegar una API key."
        case .copilot:
            return "Se detecta con `gh auth token` o puedes pegar un token con acceso a Copilot."
        case .claude:
            return "Se detecta en el Keychain de Claude Code. Si caducó, abre Claude Code para renovarla."
        case .liteLLM:
            return "Se detecta en el Keychain de Claude Usage Tracker o en la configuración de Claude Code."
        }
    }

    /// Accept the former provider identifier when decoding existing local data.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        if value == Self.legacyLiteLLMIdentifier {
            self = .liteLLM
            return
        }
        guard let provider = ProviderID(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Proveedor desconocido."
            )
        }
        self = provider
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func persistedID(_ value: String) -> ProviderID? {
        value == legacyLiteLLMIdentifier ? .liteLLM : ProviderID(rawValue: value)
    }
}

public enum PlanPriceKind: String, Codable, Hashable, Sendable {
    /// Precio mensual habitual, pagado por el usuario.
    case personal
    /// Precio mensual por asiento; puede estar pagado por la organización.
    case perSeat
    /// Incluido en una cuenta de organización, sin coste directo.
    case included
}

public struct PlanOption: Identifiable, Hashable, Sendable {
    public let name: String
    public let priceUSD: Double
    public let kind: PlanPriceKind
    public let note: String?

    public var id: String { name }

    public init(
        name: String,
        priceUSD: Double,
        kind: PlanPriceKind = .personal,
        note: String? = nil
    ) {
        self.name = name
        self.priceUSD = priceUSD
        self.kind = kind
        self.note = note
    }
}

// MARK: - Quotas

public enum ProviderStatus: String, Codable, Sendable {
    case ok
    case needsAuth
    case error
    case stale
    case loading

    public var isUsable: Bool {
        self == .ok || self == .stale
    }

    public var label: String {
        switch self {
        case .ok: return "OK"
        case .needsAuth: return "Reautenticar"
        case .error: return "Error"
        case .stale: return "Desactualizado"
        case .loading: return "Cargando"
        }
    }
}

public struct QuotaWindow: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var windowDuration: TimeInterval?
    public var detail: String?
    public var isUnlimited: Bool
    public var usedValue: Double?
    public var limitValue: Double?

    public init(
        id: String,
        label: String,
        usedPercent: Double,
        resetsAt: Date? = nil,
        windowDuration: TimeInterval? = nil,
        detail: String? = nil,
        isUnlimited: Bool = false,
        usedValue: Double? = nil,
        limitValue: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
        self.detail = detail
        self.isUnlimited = isUnlimited
        self.usedValue = usedValue
        self.limitValue = limitValue
    }

    public var clampedPercent: Double {
        min(max(usedPercent, 0), 100)
    }

    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

public struct TokenBreakdown: Codable, Hashable, Sendable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var unknown: Int

    public init(
        input: Int = 0,
        output: Int = 0,
        cacheRead: Int = 0,
        cacheWrite: Int = 0,
        unknown: Int = 0
    ) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.unknown = unknown
    }

    public static let zero = TokenBreakdown()

    public var total: Int {
        input + output + cacheRead + cacheWrite + unknown
    }

    public static func + (lhs: TokenBreakdown, rhs: TokenBreakdown) -> TokenBreakdown {
        TokenBreakdown(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            unknown: lhs.unknown + rhs.unknown
        )
    }

    public static func += (lhs: inout TokenBreakdown, rhs: TokenBreakdown) {
        lhs = lhs + rhs
    }
}

public struct ModelUsage: Codable, Identifiable, Hashable, Sendable {
    public var model: String
    public var tokens: TokenBreakdown
    public var costUSD: Double?

    public var id: String { model }

    public init(model: String, tokens: TokenBreakdown, costUSD: Double? = nil) {
        self.model = model
        self.tokens = tokens
        self.costUSD = costUSD
    }
}

public struct ProviderSnapshot: Codable, Identifiable, Sendable {
    public var provider: ProviderID
    public var fetchedAt: Date
    public var planName: String
    public var status: ProviderStatus
    public var windows: [QuotaWindow]
    public var models: [ModelUsage]
    public var errorMessage: String?
    public var accountLabel: String?

    public var id: String { provider.rawValue }

    public init(
        provider: ProviderID,
        fetchedAt: Date = Date(),
        planName: String,
        status: ProviderStatus,
        windows: [QuotaWindow] = [],
        models: [ModelUsage] = [],
        errorMessage: String? = nil,
        accountLabel: String? = nil
    ) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.planName = planName
        self.status = status
        self.windows = windows
        self.models = models
        self.errorMessage = errorMessage
        self.accountLabel = accountLabel
    }

    public var worstPercent: Double? {
        windows
            .filter { !$0.isUnlimited }
            .map(\.usedPercent)
            .max()
    }

    /// AI credits consumidos en el ciclo de cuota actual (solo Copilot).
    public var creditsUsed: Double? {
        windows.first(where: { $0.id == "credits" })?.usedValue
    }

    public static func failure(
        provider: ProviderID,
        planName: String,
        error: Error
    ) -> ProviderSnapshot {
        let status: ProviderStatus
        let message: String

        if let providerError = error as? ProviderError {
            switch providerError {
            case .auth, .missingCredential:
                status = .needsAuth
            default:
                status = .error
            }
            message = providerError.localizedDescription
        } else {
            status = .error
            message = error.localizedDescription
        }

        return ProviderSnapshot(
            provider: provider,
            planName: planName,
            status: status,
            errorMessage: message
        )
    }
}

// MARK: - Subscriptions

public enum PriceSource: String, Codable, Hashable, Sendable {
    /// El plan y el precio se mantienen sincronizados con lo que detecta el proveedor.
    case auto
    /// El usuario ha elegido plan o precio manualmente y la detección no lo sobrescribe.
    case manual

    public var label: String {
        switch self {
        case .auto: return "Detectado"
        case .manual: return "Manual"
        }
    }
}

public struct Subscription: Codable, Identifiable, Hashable, Sendable {
    public var id: ProviderID
    public var planName: String
    public var monthlyPriceUSD: Double
    public var renewalDate: Date?
    public var autoRenewal: Bool
    public var isActive: Bool
    public var priceSource: PriceSource

    public init(
        id: ProviderID,
        planName: String,
        monthlyPriceUSD: Double,
        renewalDate: Date? = nil,
        autoRenewal: Bool = true,
        isActive: Bool = true,
        priceSource: PriceSource = .auto
    ) {
        self.id = id
        self.planName = planName
        self.monthlyPriceUSD = monthlyPriceUSD
        self.renewalDate = renewalDate
        self.autoRenewal = autoRenewal
        self.isActive = isActive
        self.priceSource = priceSource
    }

    public static func `default`(for provider: ProviderID) -> Subscription {
        Subscription(
            id: provider,
            planName: provider.defaultPlanName,
            monthlyPriceUSD: provider.defaultMonthlyPriceUSD,
            priceSource: .auto
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case planName
        case monthlyPriceUSD
        case renewalDate
        case autoRenewal
        case isActive
        case priceSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        planName = try container.decode(String.self, forKey: .planName)
        monthlyPriceUSD = try container.decode(Double.self, forKey: .monthlyPriceUSD)
        renewalDate = try container.decodeIfPresent(Date.self, forKey: .renewalDate)
        autoRenewal = try container.decodeIfPresent(Bool.self, forKey: .autoRenewal) ?? true
        isActive = try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true
        // Los estados antiguos no guardaban el origen del precio. Se marcan como
        // manuales para no perder precios personalizados; StateStore los migra a
        // automáticos solo cuando coinciden exactamente con el catálogo.
        priceSource = try container.decodeIfPresent(PriceSource.self, forKey: .priceSource) ?? .manual
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(planName, forKey: .planName)
        try container.encode(monthlyPriceUSD, forKey: .monthlyPriceUSD)
        try container.encodeIfPresent(renewalDate, forKey: .renewalDate)
        try container.encode(autoRenewal, forKey: .autoRenewal)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(priceSource, forKey: .priceSource)
    }
}

// MARK: - Plan detection

public enum CopilotPlanCatalog {
    /// Normaliza los valores de `copilot_plan` de GitHub a los nombres del catálogo.
    public static func normalizedName(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "free":
            return "Free"
        case "individual", "individual_pro", "pro":
            return "Pro"
        case "individual_pro_plus", "pro_plus", "pro+":
            return "Pro+"
        case "business":
            return "Business"
        case "enterprise":
            return "Enterprise"
        default:
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Copilot"
            }
            return raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Settings

public enum MenuBarMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case iconOnly
    case worstPercent
    case compact
    case monthlyCost

    public var id: String { rawValue }

    /// Modos visibles en Ajustes. `monthlyCost` se conserva solo para decodificar
    /// estados antiguos; ya no se ofrece porque la app no muestra coste mensual.
    public static var selectableCases: [MenuBarMode] {
        [.iconOnly, .worstPercent, .compact]
    }

    public var label: String {
        switch self {
        case .iconOnly: return "Solo icono"
        case .worstPercent: return "Peor porcentaje"
        case .compact: return "Iconos por proveedor"
        case .monthlyCost: return "Coste mensual"
        }
    }
}

public enum Currency: String, Codable, CaseIterable, Identifiable, Sendable {
    case usd
    case eur

    /// Tipo de cambio interno para mostrar estimaciones en EUR.
    /// No es configurable desde la interfaz.
    public static let usdToEURRate: Double = 0.92

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .usd: return "USD ($)"
        case .eur: return "EUR (€)"
        }
    }

    public var symbol: String {
        switch self {
        case .usd: return "$"
        case .eur: return "€"
        }
    }
}

public enum AppAppearance: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Claro"
        case .dark: return "Oscuro"
        }
    }
}

public struct AppSettings: Codable, Sendable {
    public static let minimumRefreshMinutes = 5
    public static let refreshMinuteOptions = [minimumRefreshMinutes, 15, 30, 60]

    public var refreshMinutes: Int
    public var menuBarMode: MenuBarMode
    public var alertsEnabled: Bool
    public var alertThresholds: [Double]
    public var launchAtLogin: Bool
    public var currency: Currency
    public var appearance: AppAppearance
    public var showEstimates: Bool
    public var subscriptions: [Subscription]

    public init(
        refreshMinutes: Int = 5,
        menuBarMode: MenuBarMode = .compact,
        alertsEnabled: Bool = true,
        alertThresholds: [Double] = [75, 90, 100],
        launchAtLogin: Bool = true,
        currency: Currency = .usd,
        appearance: AppAppearance = .system,
        showEstimates: Bool = true,
        subscriptions: [Subscription] = ProviderID.allCases.map { Subscription.default(for: $0) }
    ) {
        self.refreshMinutes = max(Self.minimumRefreshMinutes, refreshMinutes)
        self.menuBarMode = menuBarMode
        self.alertsEnabled = alertsEnabled
        self.alertThresholds = alertThresholds
        self.launchAtLogin = launchAtLogin
        self.currency = currency
        self.appearance = appearance
        self.showEstimates = showEstimates
        self.subscriptions = subscriptions
    }

    private enum CodingKeys: String, CodingKey {
        case refreshMinutes
        case menuBarMode
        case alertsEnabled
        case alertThresholds
        case launchAtLogin
        case currency
        case appearance
        case showEstimates
        case subscriptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            refreshMinutes: try container.decodeIfPresent(Int.self, forKey: .refreshMinutes)
                ?? Self.minimumRefreshMinutes,
            menuBarMode: try container.decodeIfPresent(MenuBarMode.self, forKey: .menuBarMode) ?? .compact,
            alertsEnabled: try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true,
            alertThresholds: try container.decodeIfPresent([Double].self, forKey: .alertThresholds) ?? [75, 90, 100],
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true,
            currency: try container.decodeIfPresent(Currency.self, forKey: .currency) ?? .usd,
            appearance: try container.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system,
            showEstimates: try container.decodeIfPresent(Bool.self, forKey: .showEstimates) ?? true,
            subscriptions: try container.decodeIfPresent([Subscription].self, forKey: .subscriptions)
                ?? ProviderID.allCases.map { Subscription.default(for: $0) }
        )
    }

    public static var `default`: AppSettings {
        AppSettings()
    }

    public func subscription(for provider: ProviderID) -> Subscription? {
        subscriptions.first(where: { $0.id == provider })
    }

    public var totalMonthlyUSD: Double {
        subscriptions
            .filter(\.isActive)
            .map(\.monthlyPriceUSD)
            .reduce(0, +)
    }

    public var activeSubscriptions: [Subscription] {
        subscriptions.filter(\.isActive)
    }

    /// Proveedores que participan en el refresco, la barra de menús y las alertas.
    public var activeProviderIDs: Set<ProviderID> {
        Set(activeSubscriptions.map(\.id))
    }
}

// MARK: - Alerts

public enum AlertSeverity: String, Codable, Sendable {
    case info
    case warning
    case critical
}

public struct AppAlert: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var provider: ProviderID
    public var title: String
    public var message: String
    public var date: Date
    public var severity: AlertSeverity

    public init(
        id: UUID = UUID(),
        provider: ProviderID,
        title: String,
        message: String,
        date: Date = Date(),
        severity: AlertSeverity
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.message = message
        self.date = date
        self.severity = severity
    }
}

// MARK: - History

public struct DailyUsage: Codable, Identifiable, Hashable, Sendable {
    public var date: Date
    public var provider: ProviderID
    public var tokens: TokenBreakdown
    public var costUSD: Double?
    /// AI credits consumidos **en ese dia** (solo Copilot).
    ///
    /// La API de Copilot solo expone el acumulado del ciclo de cuota, asi que
    /// el consumo diario se obtiene restando el acumulado del dia anterior.
    public var creditsUsed: Double?
    /// AI credits consumidos acumulados en el ciclo de cuota hasta ese dia.
    /// Es el valor que devuelve la API y sirve para calcular el diario.
    public var creditsCumulative: Double?
    public var models: [ModelUsage]

    public var id: Date { date }

    public init(
        date: Date,
        provider: ProviderID,
        tokens: TokenBreakdown = .zero,
        costUSD: Double? = nil,
        creditsUsed: Double? = nil,
        creditsCumulative: Double? = nil,
        models: [ModelUsage] = []
    ) {
        self.date = date
        self.provider = provider
        self.tokens = tokens
        self.costUSD = costUSD
        self.creditsUsed = creditsUsed
        self.creditsCumulative = creditsCumulative
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case date, provider, tokens, costUSD, creditsUsed, creditsCumulative, models
        /// Campo antiguo: Copilot guardaba aqui los premium requests
        /// acumulados del ciclo. GitHub los sustituyo por AI credits, que se
        /// valoran igual en numero pero a 0,01 USD en vez de 0,04.
        case legacyPremiumRequests = "premiumRequests"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        tokens = try container.decodeIfPresent(TokenBreakdown.self, forKey: .tokens) ?? .zero
        costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
        creditsUsed = try container.decodeIfPresent(Double.self, forKey: .creditsUsed)
        creditsCumulative = try container.decodeIfPresent(Double.self, forKey: .creditsCumulative)
        models = try container.decodeIfPresent([ModelUsage].self, forKey: .models) ?? []

        // Migracion desde el formato de premium requests: el valor era el
        // acumulado del ciclo, asi que pasa a creditsCumulative.
        if creditsCumulative == nil,
           let legacy = try container.decodeIfPresent(Double.self, forKey: .legacyPremiumRequests) {
            creditsCumulative = legacy
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(provider, forKey: .provider)
        try container.encode(tokens, forKey: .tokens)
        try container.encodeIfPresent(costUSD, forKey: .costUSD)
        try container.encodeIfPresent(creditsUsed, forKey: .creditsUsed)
        try container.encodeIfPresent(creditsCumulative, forKey: .creditsCumulative)
        try container.encode(models, forKey: .models)
    }
}

// MARK: - Persistence

public struct PersistedState: Codable {
    public var version: Int
    public var settings: AppSettings
    public var snapshots: [String: ProviderSnapshot]
    public var history: [String: [DailyUsage]]
    public var alertKeys: [String: Date]
    public var alerts: [AppAlert]
    public var lastRefresh: Date?
    public var catalog: ModelCatalog?

    public init(
        version: Int = 2,
        settings: AppSettings = .default,
        snapshots: [String: ProviderSnapshot] = [:],
        history: [String: [DailyUsage]] = [:],
        alertKeys: [String: Date] = [:],
        alerts: [AppAlert] = [],
        lastRefresh: Date? = nil,
        catalog: ModelCatalog? = nil
    ) {
        self.version = version
        self.settings = settings
        self.snapshots = snapshots
        self.history = history
        self.alertKeys = alertKeys
        self.alerts = alerts
        self.lastRefresh = lastRefresh
        self.catalog = catalog
    }

    public static func fresh() -> PersistedState {
        PersistedState()
    }
}

// MARK: - Credentials

public enum CredentialStatus: String, Codable, Sendable {
    case detected
    case manual
    case missing
    case expired
    case notRequired
    /// El proveedor está desactivado; no se leen sus credenciales.
    case disabled

    public var label: String {
        switch self {
        case .detected: return "Detectada"
        case .manual: return "Manual"
        case .missing: return "No encontrada"
        case .expired: return "Caducada"
        case .notRequired: return "No necesaria"
        case .disabled: return "Desactivada"
        }
    }
}

public struct ResolvedCredentials: Sendable {
    public var openCodeKey: String?
    public var copilotToken: String?
    public var claude: ClaudeCredentials?
    public var liteLLMKey: String?
    public var statuses: [ProviderID: CredentialStatus]

    public init(
        openCodeKey: String? = nil,
        copilotToken: String? = nil,
        claude: ClaudeCredentials? = nil,
        liteLLMKey: String? = nil,
        statuses: [ProviderID: CredentialStatus] = [:]
    ) {
        self.openCodeKey = openCodeKey
        self.copilotToken = copilotToken
        self.claude = claude
        self.liteLLMKey = liteLLMKey
        self.statuses = statuses
    }
}

public struct ClaudeCredentials: Sendable {
    public var accessToken: String
    public var expiresAt: Date?
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(
        accessToken: String,
        expiresAt: Date? = nil,
        subscriptionType: String? = nil,
        rateLimitTier: String? = nil
    ) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }

    public var inferredPlan: String? {
        let type = (subscriptionType ?? "").lowercased()
        let tier = (rateLimitTier ?? "").lowercased()

        // La cuenta de organización manda sobre el nivel técnico de límites.
        if type.contains("enterprise") { return "Enterprise" }
        if type.contains("team") { return "Team" }

        if tier.contains("max_20x") || tier.contains("max-20x") || tier.contains("max20x") {
            return "Max 20x"
        }
        if tier.contains("max_5x") || tier.contains("max-5x") || tier.contains("max5x") {
            return "Max 5x"
        }
        if tier.contains("enterprise") { return "Enterprise" }
        if tier.contains("team") { return "Team" }
        // Claude Enterprise suele usar el tier `default_claude_zero`.
        if tier.contains("zero") { return "Enterprise" }

        switch type {
        case "pro": return "Pro"
        case "max": return "Max 5x"
        case "free": return "Free"
        case "enterprise": return "Enterprise"
        case "team": return "Team"
        default: return nil
        }
    }
}

// MARK: - Errors

public enum ProviderError: LocalizedError, Sendable {
    case missingCredential(String)
    case auth(String)
    case http(Int, String)
    case decoding(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .missingCredential(let message):
            return message
        case .auth(let message):
            return message
        case .http(let status, let message):
            return "Error HTTP \(status). \(message)"
        case .decoding(let message):
            return "Respuesta no reconocida: \(message)"
        case .network(let message):
            return "Error de red: \(message)"
        }
    }
}
