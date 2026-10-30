import Foundation
import Darwin
import UsageTrackerCore

// Comprobaciones del núcleo sin dependencias externas.
// Uso: swift run UsageTrackerSelfTest

var totalChecks = 0
var failures = 0

func check(_ condition: Bool, _ message: String, line: UInt = #line) {
    totalChecks += 1
    if !condition {
        failures += 1
        print("✗ \(message) (línea \(line))")
    }
}

func checkEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String, line: UInt = #line) {
    totalChecks += 1
    if lhs != rhs {
        failures += 1
        print("✗ \(message): «\(lhs)» != «\(rhs)» (línea \(line))")
    }
}

func checkClose(_ lhs: Double, _ rhs: Double, _ message: String, tolerance: Double = 0.0001, line: UInt = #line) {
    totalChecks += 1
    if abs(lhs - rhs) > tolerance {
        failures += 1
        print("✗ \(message): \(lhs) != \(rhs) (línea \(line))")
    }
}

func section(_ name: String) {
    print("• \(name)")
}

// MARK: - Modelos

section("Modelos y formato")

let tokens = TokenBreakdown(input: 1, output: 2, cacheRead: 3, cacheWrite: 4, unknown: 5)
checkEqual(tokens.total, 15, "suma de tokens")
checkEqual((tokens + tokens).total, 30, "suma de desgloses")

checkEqual(QuotaWindow(id: "w", label: "W", usedPercent: 130).clampedPercent, 100, "porcentaje limitado a 100")
checkEqual(QuotaWindow(id: "w", label: "W", usedPercent: 130).remainingPercent, 0, "restante nunca negativo")
checkEqual(QuotaWindow(id: "w", label: "W", usedPercent: -5).clampedPercent, 0, "porcentaje limitado a 0")
checkEqual(QuotaWindow(id: "w", label: "W", usedPercent: 25).remainingPercent, 75, "porcentaje restante")

let defaultSettings = AppSettings.default
checkEqual(defaultSettings.subscriptions.count, ProviderID.allCases.count, "suscripción por proveedor")
checkClose(defaultSettings.totalMonthlyUSD, 49, "coste mensual por defecto")
checkEqual(defaultSettings.activeSubscriptions.count, 3, "suscripciones activas por defecto")
checkClose(Currency.usdToEURRate, 0.92, "tipo de cambio interno fijo")

let customSettings = AppSettings(subscriptions: [
    Subscription(id: .claude, planName: "Pro", monthlyPriceUSD: 20, isActive: false),
    Subscription(id: .copilot, planName: "Business", monthlyPriceUSD: 19, isActive: true)
])
checkClose(customSettings.totalMonthlyUSD, 19, "solo cuenta suscripciones activas")
checkEqual(customSettings.activeSubscriptions.count, 1, "filtro de activas")
checkEqual(defaultSettings.activeProviderIDs.count, 3, "todos los proveedores activos por defecto")
check(!customSettings.activeProviderIDs.contains(.claude), "un proveedor desactivado no está activo")
check(customSettings.activeProviderIDs.contains(.copilot), "un proveedor activo sigue presente")
checkEqual(CredentialStatus.disabled.label, "Desactivada", "etiqueta de credencial desactivada")
checkEqual(customSettings.subscription(for: .claude)?.planName, "Pro", "búsqueda de suscripción")

let expired = ClaudeCredentials(accessToken: "token", expiresAt: Date().addingTimeInterval(-3_600))
check(expired.isExpired, "token caducado detectado")
let valid = ClaudeCredentials(accessToken: "token", expiresAt: Date().addingTimeInterval(3_600))
check(!valid.isExpired, "token vigente detectado")
checkEqual(ClaudeCredentials(accessToken: "t", rateLimitTier: "max_20x").inferredPlan, "Max 20x", "plan Max 20x")
checkEqual(ClaudeCredentials(accessToken: "t", rateLimitTier: "max_5x").inferredPlan, "Max 5x", "plan Max 5x")
checkEqual(ClaudeCredentials(accessToken: "t", subscriptionType: "pro").inferredPlan, "Pro", "plan Pro")
checkEqual(ClaudeCredentials(accessToken: "t", subscriptionType: "enterprise").inferredPlan, "Enterprise", "plan Enterprise")
checkEqual(ClaudeCredentials(accessToken: "t", subscriptionType: "team").inferredPlan, "Team", "plan Team")
checkEqual(ClaudeCredentials(accessToken: "t", rateLimitTier: "default_claude_zero").inferredPlan, "Enterprise", "tier zero = Enterprise")
checkEqual(ClaudeCredentials(accessToken: "t").inferredPlan, nil, "plan desconocido")

checkEqual(ProviderID.claude.planOption(named: "Enterprise")?.priceUSD, 0, "Enterprise sin coste directo")
checkEqual(ProviderID.claude.planOption(named: "Enterprise")?.kind, .included, "Enterprise incluido")
checkEqual(ProviderID.copilot.planOption(named: "Business")?.priceUSD, 19, "precio Copilot Business")
checkEqual(ProviderID.copilot.planOption(named: "Business")?.kind, .perSeat, "Business por asiento")
check(ProviderID.copilot.supportsPlanDetection, "Copilot detecta el plan")
check(ProviderID.claude.supportsPlanDetection, "Claude detecta el plan")
check(!ProviderID.opencodeGo.supportsPlanDetection, "OpenCode no detecta el plan")
checkEqual(CopilotPlanCatalog.normalizedName("individual_pro"), "Pro", "normaliza Copilot Pro")
checkEqual(CopilotPlanCatalog.normalizedName("individual_pro_plus"), "Pro+", "normaliza Copilot Pro+")
checkEqual(CopilotPlanCatalog.normalizedName("business"), "Business", "normaliza Copilot Business")
checkEqual(CopilotPlanCatalog.normalizedName(nil), "Copilot", "normaliza Copilot desconocido")
checkEqual(Subscription.default(for: .claude).priceSource, .auto, "las suscripciones nuevas son automáticas")

let legacySubscriptionJSON = """
{"id":"claude","planName":"Pro","monthlyPriceUSD":20,"autoRenewal":true,"isActive":true}
""".data(using: .utf8)!
do {
    let decoded = try JSONDecoder().decode(Subscription.self, from: legacySubscriptionJSON)
    checkEqual(decoded.priceSource, .manual, "suscripción antigua decodificada como manual")
    checkEqual(decoded.planName, "Pro", "plan antiguo conservado")
} catch {
    check(false, "decodificación de suscripción antigua: \(error)")
}

let autoSubscription = Subscription(
    id: .claude,
    planName: "Enterprise",
    monthlyPriceUSD: 0,
    priceSource: .auto
)
do {
    let data = try JSONEncoder().encode(autoSubscription)
    let decoded = try JSONDecoder().decode(Subscription.self, from: data)
    checkEqual(decoded.priceSource, .auto, "origen del precio persistido")
} catch {
    check(false, "ida y vuelta de suscripción: \(error)")
}

if let day = DateUtils.parseDay("2026-10-27") {
    checkEqual(DateUtils.dayKey(day), "2026-10-27", "ida y vuelta de fecha")
} else {
    check(false, "parseDay debería aceptar 2026-10-27")
}

// La vía rápida de parseo debe coincidir exactamente con `DateFormatter`.
let referenceFormatter = DateFormatter()
referenceFormatter.locale = Locale(identifier: "en_US_POSIX")
referenceFormatter.timeZone = TimeZone.current
referenceFormatter.dateFormat = "yyyy-MM-dd"
for sample in ["1970-01-01", "1999-12-31", "2024-02-29", "2026-06-15", "2038-01-19"] {
    let expected = referenceFormatter.date(from: sample)
    let actual = DateUtils.fastParseDay(sample)
    if let expected, let actual {
        checkEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970,
                   "parseo rápido coincide con DateFormatter para \(sample)")
    } else {
        check(false, "parseo rápido debería aceptar \(sample)")
    }
}
check(DateUtils.fastParseDay("no-es-fecha") == nil, "el parseo rápido rechaza formatos inválidos")
check(DateUtils.fastParseDay("2026-13-01") == nil, "el parseo rápido rechaza meses inválidos")
check(DateUtils.fastParseDay("2026-01-32") == nil, "el parseo rápido rechaza días inválidos")

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
checkEqual(DateUtils.countdown(to: fixedNow.addingTimeInterval(3_661), now: fixedNow), "1h 1m", "cuenta atrás con horas")
checkEqual(DateUtils.countdown(to: fixedNow.addingTimeInterval(90), now: fixedNow), "1m", "cuenta atrás con minutos")
checkEqual(DateUtils.countdown(to: nil, now: fixedNow), "sin fecha", "cuenta atrás sin fecha")

checkEqual(NumberFormat.compact(999), "999", "formato compacto de 999")
checkEqual(NumberFormat.compact(1_500), "1.5K", "formato compacto de 1,5K")
checkEqual(NumberFormat.compact(2_000_000), "2.0M", "formato compacto de 2M")

checkEqual(MenuBarMode.allCases.count, 4, "modos de barra de menús")
checkEqual(MenuBarMode.selectableCases.count, 3, "modos de barra de menús visibles")
check(!MenuBarMode.selectableCases.contains(.monthlyCost), "el coste mensual ya no se ofrece en la barra")
checkEqual(Currency.eur.symbol, "€", "símbolo EUR")
checkEqual(Currency.usd.symbol, "$", "símbolo USD")
checkEqual(ProviderID.opencodeGo.shortName, "OC", "abreviatura OpenCode")
checkEqual(ProviderID.allCases.map(\.rawValue), ["copilot", "claude", "opencode-go"], "orden de proveedores")

// MARK: - Previsión

section("Previsión")

let forecastNow = Date(timeIntervalSince1970: 1_800_000_000)
let monthlyWindow = QuotaWindow(
    id: "monthly",
    label: "Mensual",
    usedPercent: 50,
    resetsAt: forecastNow.addingTimeInterval(5 * 3_600),
    windowDuration: 10 * 3_600
)
if let forecast = ForecastCalculator.forecast(window: monthlyWindow, now: forecastNow) {
    checkClose(forecast.projectedPercent, 100, "proyección al final de la ventana")
    checkClose(forecast.burnPerHour, 10, "consumo por hora")
    checkEqual(forecast.confidence, .high, "confianza alta con la mitad transcurrida")
    check(forecast.willExceed, "la previsión debe marcar exceso")
} else {
    check(false, "se esperaba una previsión para la ventana mensual")
}

func forecastFor(elapsedHours: Double) -> Forecast? {
    let duration = 10 * 3_600.0
    return ForecastCalculator.forecast(
        window: QuotaWindow(
            id: "w",
            label: "Ventana",
            usedPercent: 10,
            resetsAt: forecastNow.addingTimeInterval(duration - elapsedHours * 3_600),
            windowDuration: duration
        ),
        now: forecastNow
    )
}

checkEqual(forecastFor(elapsedHours: 0.5)?.confidence, .low, "confianza baja al inicio")
checkEqual(forecastFor(elapsedHours: 2)?.confidence, .medium, "confianza media")
checkEqual(forecastFor(elapsedHours: 6)?.confidence, .high, "confianza alta")

check(ForecastCalculator.forecast(
    window: QuotaWindow(id: "w", label: "Sin reset", usedPercent: 40),
    now: forecastNow
) == nil, "sin fecha de reinicio no hay previsión")

check(ForecastCalculator.forecast(
    window: QuotaWindow(id: "w", label: "Sin duración", usedPercent: 40, resetsAt: forecastNow.addingTimeInterval(3_600)),
    now: forecastNow
) == nil, "sin duración no hay previsión")

check(ForecastCalculator.forecast(
    window: QuotaWindow(
        id: "w",
        label: "Ilimitada",
        usedPercent: 40,
        resetsAt: forecastNow.addingTimeInterval(3_600),
        windowDuration: 10 * 3_600,
        isUnlimited: true
    ),
    now: forecastNow
) == nil, "una ventana ilimitada no tiene previsión")

check(ForecastCalculator.forecast(
    window: QuotaWindow(
        id: "w",
        label: "Caducada",
        usedPercent: 40,
        resetsAt: forecastNow.addingTimeInterval(-60),
        windowDuration: 10 * 3_600
    ),
    now: forecastNow
) == nil, "una ventana ya reiniciada no tiene previsión")

// MARK: - Alertas

section("Alertas")

func alertSnapshot(percent: Double, resetsAt: Date? = nil) -> ProviderSnapshot {
    ProviderSnapshot(
        provider: .opencodeGo,
        planName: "Go",
        status: .ok,
        windows: [QuotaWindow(id: "monthly", label: "Mensual", usedPercent: percent, resetsAt: resetsAt)]
    )
}

let alertSettings = AppSettings(alertsEnabled: true, alertThresholds: [75, 90, 100])

let firstAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 80)],
    settings: alertSettings,
    existingKeys: [:],
    now: forecastNow
)
checkEqual(firstAlert.newAlerts.count, 1, "una alerta al cruzar el 75%")
checkEqual(firstAlert.newAlerts.first?.severity, .info, "severidad informativa")
checkEqual(firstAlert.keys.count, 1, "clave de deduplicación creada")
check(firstAlert.newAlerts.first?.title.contains("75%") == true, "el título menciona el umbral")

let warningAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 95)],
    settings: alertSettings,
    existingKeys: [:],
    now: forecastNow
)
checkEqual(warningAlert.newAlerts.first?.severity, .warning, "severidad de aviso al 90%")

let criticalAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 100)],
    settings: alertSettings,
    existingKeys: [:],
    now: forecastNow
)
checkEqual(criticalAlert.newAlerts.first?.severity, .critical, "severidad crítica al 100%")

let repeatedAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 82)],
    settings: alertSettings,
    existingKeys: firstAlert.keys,
    now: forecastNow
)
check(repeatedAlert.newAlerts.isEmpty, "no se repite la alerta en la misma ventana")

let escalatedAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 95)],
    settings: alertSettings,
    existingKeys: firstAlert.keys,
    now: forecastNow
)
checkEqual(escalatedAlert.newAlerts.count, 1, "sí avisa al cruzar un umbral nuevo")
checkEqual(escalatedAlert.newAlerts.first?.severity, .warning, "aviso del nuevo umbral")

let firstReset = forecastNow.addingTimeInterval(86_400)
let windowAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 80, resetsAt: firstReset)],
    settings: AppSettings(alertsEnabled: true, alertThresholds: [75]),
    existingKeys: [:],
    now: forecastNow
)
checkEqual(windowAlert.newAlerts.count, 1, "alerta con fecha de reinicio")

let nextWindowAlert = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 80, resetsAt: firstReset.addingTimeInterval(30 * 86_400))],
    settings: AppSettings(alertsEnabled: true, alertThresholds: [75]),
    existingKeys: windowAlert.keys,
    now: forecastNow
)
checkEqual(nextWindowAlert.newAlerts.count, 1, "una ventana nueva vuelve a avisar")

let disabledAlerts = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 99)],
    settings: AppSettings(alertsEnabled: false, alertThresholds: [75]),
    existingKeys: [:],
    now: forecastNow
)
check(disabledAlerts.newAlerts.isEmpty, "las alertas desactivadas no se disparan")

var failedSnapshot = alertSnapshot(percent: 99)
failedSnapshot.status = .error
let failedAlerts = AlertEngine.evaluate(
    snapshots: [.opencodeGo: failedSnapshot],
    settings: AppSettings(alertsEnabled: true, alertThresholds: [75]),
    existingKeys: [:],
    now: forecastNow
)
check(failedAlerts.newAlerts.isEmpty, "un proveedor con error no genera alertas de cuota")

var inactiveProviderSettings = AppSettings(alertsEnabled: true, alertThresholds: [75])
if let index = inactiveProviderSettings.subscriptions.firstIndex(where: { $0.id == .opencodeGo }) {
    inactiveProviderSettings.subscriptions[index].isActive = false
}
let inactiveProviderAlerts = AlertEngine.evaluate(
    snapshots: [.opencodeGo: alertSnapshot(percent: 99)],
    settings: inactiveProviderSettings,
    existingKeys: [:],
    now: forecastNow
)
check(inactiveProviderAlerts.newAlerts.isEmpty, "un proveedor desactivado no genera alertas")

// MARK: - Historial

section("Historial")

let today = DateUtils.startOfDay(Date())
let yesterday = DateUtils.daysAgo(1, from: today)

let merged = HistoryMerger.merge(
    existing: [
        DailyUsage(date: yesterday, provider: .claude, tokens: TokenBreakdown(input: 10)),
        DailyUsage(date: today, provider: .claude, tokens: TokenBreakdown(input: 20))
    ],
    incoming: [
        DailyUsage(date: today, provider: .claude, tokens: TokenBreakdown(input: 99), costUSD: 1.5)
    ]
)
checkEqual(merged.count, 2, "fusión por día")
checkEqual(merged.last?.tokens.input, 99, "el dato entrante reemplaza al anterior")
checkEqual(merged.last?.costUSD, 1.5, "el coste entrante reemplaza al anterior")

let oldMerge = HistoryMerger.merge(
    existing: [
        DailyUsage(date: DateUtils.daysAgo(400), provider: .claude),
        DailyUsage(date: DateUtils.daysAgo(2), provider: .claude)
    ],
    incoming: [],
    keepDays: 180
)
checkEqual(oldMerge.count, 1, "se descartan datos antiguos")

let sortedMerge = HistoryMerger.merge(
    existing: [
        DailyUsage(date: today, provider: .claude),
        DailyUsage(date: DateUtils.daysAgo(2, from: today), provider: .claude)
    ],
    incoming: [DailyUsage(date: DateUtils.daysAgo(1, from: today), provider: .claude)]
)
checkEqual(sortedMerge.map(\.date), sortedMerge.map(\.date).sorted(), "historial ordenado")

// MARK: - Ordenación del catálogo

section("Ordenación del catálogo")

// El orden natural debe coincidir con `localizedStandardCompare` para los
// nombres de modelo, que es lo que se usaba antes.
let sortSamples = [
    "Model 10", "Model 2", "Model 1",
    "GPT-4o", "gpt-4o mini", "Claude Opus",
    "Llama 3.1 70B", "Llama 3.10 70B"
]
let referenceOrder = sortSamples.sorted {
    $0.localizedStandardCompare($1) == .orderedAscending
}
let naturalOrder = sortSamples.sorted {
    ModelCatalogService.naturalLessThan(
        ModelCatalogService.normalizedName($0),
        ModelCatalogService.normalizedName($1)
    )
}
checkEqual(naturalOrder, referenceOrder, "el orden natural coincide con la colación del sistema")

// El catálogo se agrupa por proveedor y mantiene el orden dentro de cada uno.
let mixedCatalog = [
    CatalogModel(modelID: "b-2", name: "Model 2", provider: .claude),
    CatalogModel(modelID: "b-10", name: "Model 10", provider: .claude),
    CatalogModel(modelID: "a-1", name: "Alpha", provider: .copilot),
    CatalogModel(modelID: "c-1", name: "Zeta", provider: .opencodeGo)
]
let sortedCatalog = ModelCatalogService.sorted(mixedCatalog)
checkEqual(
    sortedCatalog.map(\.modelID),
    ["a-1", "b-2", "b-10", "c-1"],
    "el catálogo se ordena por proveedor y por nombre"
)

// MARK: - Precios

section("Precios")

checkEqual(PricingCatalog.price(for: "claude-opus-4-1").pattern, "claude-opus", "familia Opus")
checkEqual(PricingCatalog.price(for: "claude-sonnet-4-5").pattern, "claude-sonnet", "familia Sonnet")
checkEqual(PricingCatalog.price(for: "claude-haiku-4-5").pattern, "claude-haiku", "familia Haiku")
checkEqual(PricingCatalog.price(for: "desconocido").pattern, "default", "precio por defecto")

let sonnetTokens = TokenBreakdown(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 1_000_000)
checkClose(PricingCatalog.cost(model: "claude-sonnet-4-5", tokens: sonnetTokens), 3.0 + 15.0 + 0.30 + 3.75, "coste Sonnet")
checkClose(PricingCatalog.cost(model: "claude-opus-4-1", tokens: TokenBreakdown(output: 1_000_000)), 25, "coste Opus de salida")
checkClose(PricingCatalog.cost(model: "claude-haiku-4-5", tokens: TokenBreakdown(unknown: 1_000_000)), 1, "tokens desconocidos a precio de entrada")
checkClose(
    PricingCatalog.blendedRate(model: "claude-sonnet-4-5", tokens: .zero),
    PricingCatalog.price(for: "claude-sonnet-4-5").input / 1_000_000,
    "tarifa mixta sin tokens"
)

// MARK: - Catálogo de modelos

section("Catálogo de modelos")

check(
    CatalogModel(
        modelID: "free-model",
        name: "Free",
        provider: .opencodeGo,
        inputPerMillion: 0,
        outputPerMillion: 0
    ).isFree,
    "un modelo a 0 USD es gratuito"
)
check(
    !CatalogModel(
        modelID: "partly-free",
        name: "Partly free",
        provider: .opencodeGo,
        inputPerMillion: 0,
        outputPerMillion: 1
    ).isFree,
    "un modelo con salida de pago no es gratuito"
)
check(
    !CatalogModel(
        modelID: "unknown-price",
        name: "Unknown",
        provider: .opencodeGo
    ).isFree,
    "un modelo sin tarifa publicada no se marca como gratuito"
)
check(
    !CatalogModel(
        modelID: "free-cache-paid",
        name: "Free cache paid",
        provider: .opencodeGo,
        inputPerMillion: 0,
        outputPerMillion: 0,
        cacheReadPerMillion: 0.1
    ).isFree,
    "un modelo con caché de pago no se marca como gratuito"
)

let modelsFixture = """
{
  "anthropic": {
    "name": "Anthropic",
    "models": {
      "claude-opus-5-5": {
        "id": "claude-opus-5-5",
        "name": "Claude Opus 5.5",
        "reasoning": true,
        "tool_call": true,
        "cost": {"input": 4, "output": 20, "cache_read": 0.2, "cache_write": 5},
        "limit": {"context": 1000000, "output": 128000},
        "release_date": "2026-09-22",
        "last_updated": "2026-09-22",
        "status": "active",
        "canonical_model_id": "anthropic/claude-opus-5-5"
      }
    }
  },
  "github-copilot": {
    "name": "GitHub Copilot",
    "models": {
      "gpt-5.4": {
        "id": "gpt-5.4",
        "name": "GPT-5.4",
        "cost": {"input": 2.5, "output": 15},
        "limit": {"context": 1050000, "output": 128000},
        "release_date": "2025-08-07",
        "status": "deprecated",
        "canonical_model_id": "openai/gpt-5.4"
      }
    }
  },
  "opencode-go": {
    "name": "OpenCode Go",
    "models": {
      "deepseek-v4.1-flash": {
        "id": "deepseek-v4.1-flash",
        "name": "DeepSeek V4.1 Flash",
        "cost": {"input": 0.15, "output": 0.6, "cache_read": 0.003},
        "limit": {"context": 1000000, "output": 384000}
      }
    }
  },
  "openai": {
    "name": "OpenAI",
    "models": {
      "gpt-5": {"id": "gpt-5", "name": "GPT-5", "cost": {"input": 1, "output": 2}}
    }
  }
}
"""

do {
    let parsed = try ModelsDevParser.parse(data: modelsFixture.data(using: .utf8)!)
    checkEqual(parsed.count, 3, "solo se leen los proveedores soportados")
    checkEqual(
        parsed.map(\.provider),
        [.copilot, .claude, .opencodeGo],
        "orden de proveedores en el catálogo"
    )

    let opus = parsed.first { $0.modelID == "claude-opus-5-5" }
    checkEqual(opus?.provider, .claude, "proveedor del modelo")
    checkClose(opus?.inputPerMillion ?? 0, 4, "precio de entrada Opus 5.5")
    checkClose(opus?.cacheReadPerMillion ?? 0, 0.2, "precio de caché Opus 5.5")
    checkEqual(opus?.contextWindow, 1_000_000, "contexto Opus 5.5")
    checkEqual(opus?.reasoning, true, "capacidad de razonamiento")
    checkEqual(opus?.hasPublishedPrice, true, "modelo con tarifa publicada")
    checkEqual(opus?.releaseDate, "2026-09-22", "fecha de publicación")
    check(opus?.referenceDate == DateUtils.parseDay("2026-09-22"), "fecha de referencia")
    checkEqual(opus?.canonicalModelID, "anthropic/claude-opus-5-5", "id canónico")
    checkEqual(
        parsed.first(where: { $0.modelID == "gpt-5.4" })?.isDeprecated,
        true,
        "estado deprecated detectado"
    )

    let mergedCatalog = ModelCatalogService.makeCatalog(
        devModels: parsed,
        openCodeLiveIDs: ["deepseek-v4.1-flash", "brand-new-model"]
    )
    let openCodeModels = mergedCatalog.models(for: .opencodeGo)
    checkEqual(openCodeModels.count, 2, "se combina el listado en vivo de OpenCode")
    checkEqual(openCodeModels.first(where: { $0.modelID == "deepseek-v4.1-flash" })?.isLive, true, "modelo en vivo marcado")
    checkEqual(openCodeModels.first(where: { $0.modelID == "brand-new-model" })?.hasPublishedPrice, false, "modelo en vivo sin precio")
    checkEqual(mergedCatalog.models(for: .claude).count, 1, "se conservan los modelos de Claude")

    let nonLiveFree = CatalogModel(
        modelID: "longcat-2.5-preview-free",
        name: "LongCat 2.5 Preview Free",
        provider: .opencodeGo,
        inputPerMillion: 0,
        outputPerMillion: 0,
        cacheReadPerMillion: 0
    )
    let catalogWithFree = ModelCatalogService.makeCatalog(
        devModels: [nonLiveFree],
        openCodeLiveIDs: ["paid-live-model"]
    )
    check(
        catalogWithFree.models.contains { $0.modelID == nonLiveFree.modelID },
        "un modelo gratuito aparece aunque no esté en el listado en vivo"
    )
    checkEqual(
        catalogWithFree.models.first(where: { $0.modelID == nonLiveFree.modelID })?.isLive,
        false,
        "el modelo gratuito no en vivo se marca como no live"
    )

    let openCodePrices = mergedCatalog.priceTable(for: .opencodeGo)
    let deepSeekPrice = PricingCatalog.price(for: "deepseek-v4.1-flash", catalog: openCodePrices)
    checkClose(deepSeekPrice.input, 0.15, "tarifa dinámica de entrada")
    checkClose(deepSeekPrice.cacheRead, 0.003, "tarifa dinámica de caché")
    checkClose(
        PricingCatalog.cost(
            model: "deepseek-v4.1-flash",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000),
            catalog: openCodePrices
        ),
        0.75,
        "coste con tarifa dinámica"
    )
    checkEqual(
        PricingCatalog.price(for: "brand-new-model", catalog: openCodePrices).pattern,
        "default",
        "modelo sin tarifa usa el respaldo"
    )

    // El resolutor con memoria debe dar el mismo precio que la búsqueda directa.
    let resolver = PricingCatalog.Resolver(catalog: openCodePrices)
    for sample in ["deepseek-v4.1-flash", "brand-new-model", "claude-opus-5-5", "GPT-4o"] {
        let direct = PricingCatalog.price(for: sample, catalog: openCodePrices)
        let cached = resolver.price(for: sample)
        checkClose(cached.input, direct.input, "el resolutor coincide en entrada para \(sample)")
        checkClose(cached.output, direct.output, "el resolutor coincide en salida para \(sample)")
        checkClose(cached.cacheRead, direct.cacheRead, "el resolutor coincide en caché para \(sample)")
        checkClose(cached.cacheWrite, direct.cacheWrite, "el resolutor coincide en escritura para \(sample)")
    }
    checkClose(
        resolver.cost(
            model: "deepseek-v4.1-flash",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000)
        ),
        PricingCatalog.cost(
            model: "deepseek-v4.1-flash",
            tokens: TokenBreakdown(input: 1_000_000, output: 1_000_000),
            catalog: openCodePrices
        ),
        "el coste del resolutor coincide con el cálculo directo"
    )

    let claudePrices = mergedCatalog.priceTable(for: .claude)
    checkClose(
        PricingCatalog.cost(
            model: "claude-opus-5-5",
            tokens: TokenBreakdown(output: 1_000_000),
            catalog: claudePrices
        ),
        20,
        "la tarifa dinámica gana a la de respaldo"
    )
} catch {
    check(false, "parseo del catálogo de modelos: \(error)")
}

// MARK: - Recomendaciones de modelos

section("Recomendaciones de modelos")

let recommendationNow = DateUtils.parseDay("2026-10-28")!

func recommendationModel(
    id: String,
    provider: ProviderID = .opencodeGo,
    input: Double?,
    output: Double?,
    context: Int?,
    releaseDate: String?,
    status: String? = nil,
    canonical: String? = nil
) -> CatalogModel {
    CatalogModel(
        modelID: id,
        name: id,
        provider: provider,
        inputPerMillion: input,
        outputPerMillion: output,
        contextWindow: context,
        releaseDate: releaseDate,
        status: status,
        canonicalModelID: canonical
    )
}

// Los precios de estos fixtures están en el rango real del catálogo de
// OpenCode Go, cuyos topes por banda son más bajos que los de Claude y
// Copilot.
let recommendationModels = [
    recommendationModel(
        id: "ultra",
        input: 2,
        output: 10,
        context: 1_000_000,
        releaseDate: "2026-10-20",
        canonical: "vendor/ultra"
    ),
    recommendationModel(
        id: "medium",
        input: 1,
        output: 5,
        context: 200_000,
        releaseDate: "2026-09-20",
        canonical: "vendor/medium"
    ),
    recommendationModel(
        id: "light",
        input: 0.15,
        output: 0.6,
        context: 32_000,
        releaseDate: "2026-08-20",
        canonical: "vendor/light"
    ),
    recommendationModel(
        id: "old",
        input: 0.01,
        output: 0.02,
        context: 16_000,
        releaseDate: "2025-01-01"
    ),
    recommendationModel(
        id: "free",
        input: 0,
        output: 0,
        context: 1_000_000,
        releaseDate: "2026-10-01"
    ),
    recommendationModel(
        id: "unknown-price",
        input: nil,
        output: nil,
        context: 1_000_000,
        releaseDate: "2026-10-01"
    ),
    recommendationModel(
        id: "deprecated",
        input: 1,
        output: 1,
        context: 1_000_000,
        releaseDate: "2026-10-01",
        status: "deprecated"
    ),
    recommendationModel(
        id: "too-expensive",
        input: 10,
        output: 50,
        context: 1_000_000,
        releaseDate: "2026-10-01"
    )
]

let recommendations = ModelRecommender.recommendations(
    for: .opencodeGo,
    from: recommendationModels,
    now: recommendationNow
)
checkEqual(recommendations.count, 3, "tres recomendaciones por proveedor")
checkEqual(Set(recommendations.map(\.badge)), Set(WorkloadBadge.allCases), "un badge de cada tipo")
checkEqual(Set(recommendations.map(\.model.modelID)).count, 3, "tres modelos distintos")
check(recommendations.contains { $0.badge == .ultra && $0.model.modelID == "ultra" }, "ultra usa el modelo de mayor contexto")
check(recommendations.contains { $0.badge == .medium && $0.model.modelID == "medium" }, "medium usa el modelo equilibrado")
check(recommendations.contains { $0.badge == .light && $0.model.modelID == "light" }, "light usa el modelo barato")
check(!recommendations.contains { $0.model.modelID == "old" }, "se descartan modelos de más de 6 meses")
check(!recommendations.contains { $0.model.modelID == "free" }, "se descartan gratuitos")
check(!recommendations.contains { $0.model.modelID == "unknown-price" }, "se descartan tarifas desconocidas")
check(!recommendations.contains { $0.model.modelID == "deprecated" }, "se descartan deprecated")
check(!recommendations.contains { $0.model.modelID == "too-expensive" }, "se descartan modelos por encima del tope de coste")

// Los topes de precio dependen del proveedor: OpenCode Go tiene un catálogo
// mucho más barato que Claude o Copilot.
checkClose(
    WorkloadPriceCaps.cap(.ultra, for: .opencodeGo).maxInputPerMillion,
    2.00,
    "el tope ultra de OpenCode Go es $2 de entrada"
)
checkClose(
    WorkloadPriceCaps.cap(.ultra, for: .opencodeGo).maxOutputPerMillion,
    10.00,
    "el tope ultra de OpenCode Go es $10 de salida"
)
checkClose(
    WorkloadPriceCaps.cap(.medium, for: .opencodeGo).maxInputPerMillion,
    1.50,
    "el tope medium de OpenCode Go es $1.50 de entrada"
)
checkClose(
    WorkloadPriceCaps.cap(.medium, for: .opencodeGo).maxOutputPerMillion,
    6.00,
    "el tope medium de OpenCode Go es $6 de salida"
)
checkClose(
    WorkloadPriceCaps.cap(.light, for: .opencodeGo).maxInputPerMillion,
    0.40,
    "el tope light de OpenCode Go es $0.40 de entrada"
)
checkClose(
    WorkloadPriceCaps.cap(.light, for: .opencodeGo).maxOutputPerMillion,
    1.60,
    "el tope light de OpenCode Go es $1.60 de salida"
)
checkClose(
    WorkloadPriceCaps.cap(.ultra, for: .claude).maxInputPerMillion,
    5.00,
    "Claude mantiene el tope ultra por defecto"
)
checkClose(
    WorkloadPriceCaps.cap(.ultra, for: .copilot).maxInputPerMillion,
    5.00,
    "Copilot mantiene el tope ultra por defecto"
)

// Los topes cambian el resultado según el proveedor. Un modelo de $1.20/$5.50
// entra en la banda media de OpenCode Go ($1.50/$6) pero en la ultra de
// Claude ($5/$25), porque allí la banda media solo llega a $2.50/$12.50 y el
// modelo de $2/$10 ya la ocupa.
let goMedium = recommendationModel(
    id: "go-medium",
    provider: .opencodeGo,
    input: 1.2,
    output: 5.5,
    context: 1_000_000,
    releaseDate: "2026-10-21",
    canonical: "vendor/go-medium"
)
let goMediumRecommendation = ModelRecommender.recommendations(
    for: .opencodeGo,
    from: recommendationModels + [goMedium],
    now: recommendationNow
)
check(
    goMediumRecommendation.contains { $0.model.modelID == "go-medium" },
    "un modelo de $1.20 entra en banda en OpenCode Go"
)
check(
    !goMediumRecommendation.contains { $0.badge == .ultra && $0.model.modelID == "go-medium" },
    "un modelo de $1.20 no es ultra en OpenCode Go, cuyo tope es $2"
)

let claudeMedium = recommendationModel(
    id: "claude-medium",
    provider: .claude,
    input: 1.2,
    output: 5.5,
    context: 1_000_000,
    releaseDate: "2026-10-21",
    canonical: "vendor/claude-medium"
)
let claudeMediumRecommendation = ModelRecommender.recommendations(
    for: .claude,
    from: recommendationModels + [claudeMedium],
    now: recommendationNow
)
check(
    claudeMediumRecommendation.contains { $0.model.modelID == "claude-medium" },
    "el mismo modelo también entra en banda en Claude"
)
check(
    !claudeMediumRecommendation.contains { $0.badge == .ultra && $0.model.modelID == "claude-medium" },
    "en Claude el modelo de $1.20 tampoco llega a ultra"
)

// Un modelo por encima del tope ultra del proveedor no se recomienda.
let overCap = recommendationModel(
    id: "over-cap",
    provider: .opencodeGo,
    input: 4.5,
    output: 20,
    context: 1_000_000,
    releaseDate: "2026-10-21",
    canonical: "vendor/over-cap"
)
let overCapRecommendation = ModelRecommender.recommendations(
    for: .opencodeGo,
    from: recommendationModels + [overCap],
    now: recommendationNow
)
check(
    !overCapRecommendation.contains { $0.model.modelID == "over-cap" },
    "un modelo por encima del tope ultra de OpenCode Go no se recomienda"
)

let overCapClaude = recommendationModel(
    id: "over-cap-claude",
    provider: .claude,
    input: 4.5,
    output: 20,
    context: 1_000_000,
    releaseDate: "2026-10-21",
    canonical: "vendor/over-cap-claude"
)
let overCapClaudeRecommendation = ModelRecommender.recommendations(
    for: .claude,
    from: recommendationModels + [overCapClaude],
    now: recommendationNow
)
check(
    overCapClaudeRecommendation.contains { $0.badge == .ultra && $0.model.modelID == "over-cap-claude" },
    "el mismo modelo sí es ultra en Claude, cuyo tope es $5"
)

let variant = recommendationModel(
    id: "ultra-v2",
    input: 1.8,
    output: 9,
    context: 1_000_000,
    releaseDate: "2026-10-21",
    canonical: "vendor/ultra"
)
let deduplicated = ModelRecommender.recommendations(
    for: .opencodeGo,
    from: recommendationModels + [variant],
    now: recommendationNow
)
checkEqual(
    deduplicated.filter { $0.model.canonicalModelID == "vendor/ultra" }.count,
    1,
    "las variantes canónicas se deduplican por proveedor"
)

let claudeCandidate = recommendationModel(
    id: "claude-candidate",
    provider: .claude,
    input: 5,
    output: 25,
    context: 500_000,
    releaseDate: "2026-10-01",
    canonical: "vendor/claude"
)
let claudeRecommendations = ModelRecommender.recommendations(
    for: .claude,
    from: recommendationModels + [claudeCandidate],
    now: recommendationNow
)
check(
    claudeRecommendations.contains { $0.model.provider == .claude },
    "cada proveedor calcula sus propias recomendaciones"
)

// El índice debe coincidir con el cálculo por proveedor original.
let index = RecommendationIndex.build(
    from: recommendationModels + [claudeCandidate],
    now: recommendationNow
)
checkEqual(
    index.byProvider[.opencodeGo]?.map(\.model.modelID),
    recommendations.map(\.model.modelID),
    "el índice reproduce el orden de las recomendaciones por proveedor"
)
checkEqual(
    index.byProvider[.claude]?.map(\.model.modelID),
    claudeRecommendations.map(\.model.modelID),
    "el índice reproduce las recomendaciones de Claude"
)
checkEqual(
    index.badgeByModelID["opencode-go/ultra"],
    WorkloadBadge.ultra,
    "el índice asocia el badge correcto a cada modelo"
)
checkEqual(index.orderByModelID["opencode-go/ultra"], 0, "el índice ordena por posición")
check(
    index.recommendedModelIDs.contains("claude/claude-candidate"),
    "el índice recoge los modelos recomendados de todos los proveedores"
)
check(
    index.providersBelowMinimum.contains(.copilot),
    "el índice detecta los proveedores sin suficientes modelos"
)
check(!index.providersBelowMinimum.contains(.opencodeGo), "un proveedor con 3 modelos no se marca")

// MARK: - AI credits de GitHub Copilot

section("AI credits de Copilot")

checkClose(PricingCatalog.copilotCreditUSD, 0.01, "un AI credit vale 0,01 USD")

// El importe de los credits conserva los centimos, a diferencia de `money`
// que redondea a partir de 10 USD.
checkEqual(NumberFormat.usd(189.30), "$189.30", "el importe de credits mantiene los centimos")
checkEqual(NumberFormat.usd(3.89), "$3.89", "un importe pequeno de credits")

// La respuesta real de la API de Copilot tras el cambio a AI credits.
let copilotAPIResponse = """
{
  "copilot_plan": "business",
  "quota_reset_date": "2026-11-01",
  "token_based_billing": true,
  "quota_snapshots": {
    "premium_interactions": {
      "quota_id": "premium_interactions",
      "entitlement": 20000,
      "remaining": 1070,
      "quota_remaining": 1070.2,
      "percent_remaining": 5.3,
      "credits_used": 18930,
      "unlimited": false,
      "token_based_billing": true
    }
  }
}
"""

// Se comprueba el parsing del JSON con los nombres reales de la API.
let copilotQuota = try JSONDecoder().decode(
    CopilotUserResponse.self,
    from: Data(copilotAPIResponse.utf8)
)
checkEqual(copilotQuota.quota_snapshots?["premium_interactions"]?.credits_used, 18930, "credits_used se lee")
checkClose(
    copilotQuota.quota_snapshots?["premium_interactions"]?.quota_remaining ?? 0,
    1070.2,
    "quota_remaining conserva los decimales"
)
checkEqual(copilotQuota.token_based_billing, true, "la API indica facturacion por tokens")

// El consumo diario se obtiene restando el acumulado del dia anterior.
let copilotHistory = [
    DailyUsage(date: DateUtils.parseDay("2026-10-26")!, provider: .copilot,
               creditsUsed: 120, creditsCumulative: 120),
    DailyUsage(date: DateUtils.parseDay("2026-10-27")!, provider: .copilot,
               creditsUsed: 585, creditsCumulative: 705),
    DailyUsage(date: DateUtils.parseDay("2026-10-28")!, provider: .copilot,
               creditsUsed: 389, creditsCumulative: 1094)
]
let copilotDailyTotal = copilotHistory.reduce(0.0) { $0 + ($1.creditsUsed ?? 0) }
checkClose(copilotDailyTotal, 1094, "los credits diarios suman el acumulado del ciclo")
checkClose(
    copilotDailyTotal * PricingCatalog.copilotCreditUSD,
    10.94,
    "el valor de Copilot son los credits diarios por 0,01 USD"
)

// El valor por defecto de la tarifa antigua no debe quedar en el codigo.
check(
    !String(describing: PricingCatalog.copilotCreditUSD).contains("0.04"),
    "la tarifa de premium requests se ha retirado"
)

// Migracion: el estado antiguo guardaba los premium requests acumulados.
let legacyJSON = """
{
  "date": "2026-10-28T00:00:00Z",
  "provider": "copilot",
  "tokens": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0, "unknown": 0 },
  "premiumRequests": 18930,
  "models": []
}
"""
do {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = try decoder.decode(DailyUsage.self, from: Data(legacyJSON.utf8))
    checkEqual(legacy.creditsCumulative, 18930, "el acumulado antiguo se migra a creditsCumulative")
    checkEqual(legacy.creditsUsed, nil, "el consumo diario no se inventa en la migracion")
} catch {
    check(false, "migracion del historial antiguo de Copilot: \(error)")
}

// Y el estado nuevo se guarda con los campos nuevos.
do {
    let point = DailyUsage(
        date: DateUtils.parseDay("2026-10-29")!,
        provider: .copilot,
        costUSD: 3.89,
        creditsUsed: 389,
        creditsCumulative: 19319
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(point)
    let text = String(data: data, encoding: .utf8) ?? ""
    check(text.contains("creditsUsed"), "el estado nuevo guarda creditsUsed")
    check(text.contains("creditsCumulative"), "el estado nuevo guarda creditsCumulative")
    check(!text.contains("premiumRequests"), "el estado nuevo ya no guarda premiumRequests")
} catch {
    check(false, "serializacion del historial nuevo de Copilot: \(error)")
}

// El merger crea un punto por dia con consumo y omite los dias sin consumo.
let mergerDay1 = DateUtils.parseDay("2026-10-27")!
let mergerDay2 = DateUtils.parseDay("2026-10-28")!
let mergerDay3 = DateUtils.parseDay("2026-10-29")!

// Primer punto: sin referencia anterior, todo el acumulado es de ese dia.
var mergerPoints = CopilotHistoryMerger.merge(
    existing: [], cumulative: 100, now: mergerDay1
)
checkEqual(mergerPoints.count, 1, "el primer punto crea un registro")
checkEqual(mergerPoints.first?.creditsUsed, 100, "el primer punto cuenta todo el acumulado")

// Dia con consumo: se registra la diferencia.
mergerPoints = CopilotHistoryMerger.merge(
    existing: mergerPoints, cumulative: 250, now: mergerDay2
)
checkEqual(mergerPoints.count, 2, "un dia con consumo anade registro")
checkEqual(mergerPoints.last?.creditsUsed, 150, "el consumo es la diferencia de acumulados")

// Dia sin cambio en el acumulado: no se registra, igual que OpenCode con un
// dia sin sesiones.
mergerPoints = CopilotHistoryMerger.merge(
    existing: mergerPoints, cumulative: 250, now: mergerDay3
)
checkEqual(mergerPoints.count, 2, "un dia sin consumo no anade registro")

// Actualizar el mismo dia con un acumulado mayor recalcula su consumo.
mergerPoints = CopilotHistoryMerger.merge(
    existing: mergerPoints, cumulative: 400, now: mergerDay3
)
checkEqual(mergerPoints.count, 3, "actualizar el dia actual anade el registro")
checkEqual(mergerPoints.last?.creditsUsed, 150, "el consumo del dia se recalcula")
checkEqual(mergerPoints.last?.creditsCumulative, 400, "el acumulado se actualiza")

// Si el acumulado no cambia desde la ultima vez que se vio, no hubo consumo
// ese dia y el registro se quita, para no dejar ceros falsos en la serie.
let sinCambio = CopilotHistoryMerger.merge(
    existing: mergerPoints, cumulative: 400, now: mergerDay3
)
checkEqual(sinCambio.count, 2, "un dia guardado sin cambio en el acumulado se quita")
check(
    !sinCambio.contains { DateUtils.isSameDay($0.date, mergerDay3) },
    "el dia sin consumo desaparece del historial"
)

// Reinicio del ciclo: el acumulado baja y cuenta entero como consumo.
let reinicio = CopilotHistoryMerger.merge(
    existing: mergerPoints, cumulative: 20, now: mergerDay3.addingTimeInterval(86_400)
)
checkEqual(reinicio.last?.creditsUsed, 20, "un ciclo reiniciado cuenta el acumulado entero")

// Un dia migrado, sin consumo diario, no suma al valor de uso.
let soloMigrado = [
    DailyUsage(date: mergerDay1, provider: .copilot, creditsCumulative: 17956)
].compactMap(\.creditsUsed).reduce(0, +)
checkClose(soloMigrado, 0, "un dia migrado sin consumo diario no suma al valor")

// El valor de uso de Copilot sale del acumulado del ciclo, no del historial
// diario. La API no expone el detalle por dia, asi que sumar la serie dejaria
// fuera casi todo el consumo.
let cycleSnapshot = ProviderSnapshot(
    provider: .copilot,
    planName: "Business",
    status: .ok,
    windows: [QuotaWindow(
        id: "credits",
        label: "AI credits",
        usedPercent: 94.7,
        usedValue: 18930,
        limitValue: 20000
    )]
)
checkClose(
    CopilotHistoryMerger.usageValue(snapshot: cycleSnapshot),
    189.30,
    "el valor de uso de Copilot es el acumulado del ciclo por 0,01 USD"
)
checkClose(
    CopilotHistoryMerger.usageValue(snapshot: nil),
    0,
    "sin snapshot el valor de uso de Copilot es cero"
)
checkClose(
    CopilotHistoryMerger.usageValue(
        snapshot: ProviderSnapshot(
            provider: .copilot,
            planName: "Business",
            status: .ok,
            windows: [QuotaWindow(id: "credits", label: "AI credits", usedPercent: 0)]
        )
    ),
    0,
    "un snapshot sin credits consumidos vale cero"
)

// MARK: - Actualizaciones

section("Actualizaciones")

check(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"), "detecta versión nueva")
check(UpdateChecker.isNewer("0.1.10", than: "0.1.9"), "compara componentes numéricos")
check(!UpdateChecker.isNewer("0.1.0", than: "0.1.0"), "no marca la misma versión")
check(!UpdateChecker.isNewer("v0.1.0", than: "0.2.0"), "no marca una versión anterior")

let releaseJSON = """
{
  "tag_name": "v0.2.0",
  "name": "Usage Tracker 0.2.0",
  "body": "Mejoras y correcciones",
  "html_url": "https://github.com/KemelMoh/usage-tracker/releases/tag/v0.2.0",
  "published_at": "2026-10-29T10:00:00Z",
  "assets": [
    {
      "name": "UsageTracker-0.2.0.dmg",
      "browser_download_url": "https://github.com/KemelMoh/usage-tracker/releases/download/v0.2.0/UsageTracker-0.2.0.dmg"
    }
  ]
}
"""

do {
    let update = try UpdateChecker.parse(data: releaseJSON.data(using: .utf8)!)
    checkEqual(update?.version, "0.2.0", "versión de la release")
    checkEqual(update?.dmgURL.lastPathComponent, "UsageTracker-0.2.0.dmg", "DMG de la release")
    checkEqual(update?.publishedAt != nil, true, "fecha de la release")
} catch {
    check(false, "parseo de release: \(error)")
}

// MARK: - Persistencia

section("Persistencia")

let exportDate = Date(timeIntervalSince1970: 1_700_000_000)
let payload = ExportPayload(
    settings: AppSettings(currency: .eur),
    history: [
        "claude": [
            DailyUsage(
                date: exportDate,
                provider: .claude,
                tokens: TokenBreakdown(input: 100, output: 50),
                costUSD: 0.25
            )
        ]
    ],
    alerts: [
        AppAlert(provider: .claude, title: "Aviso", message: "Mensaje", date: exportDate, severity: .warning)
    ]
)

do {
    let data = try StateStore.encodeExport(payload)
    let decoded = try StateStore.decodeExport(data)
    checkEqual(decoded.settings.currency, .eur, "moneda exportada")
    checkEqual(decoded.history["claude"]?.first?.tokens.total, 150, "tokens exportados")
    checkEqual(decoded.history["claude"]?.first?.costUSD, 0.25, "coste exportado")
    checkEqual(decoded.alerts.first?.severity, .warning, "alertas exportadas")

    let json = String(data: data, encoding: .utf8) ?? ""
    check(!json.contains("accessToken"), "el export no contiene accessToken")
    check(!json.contains("apiKey"), "el export no contiene apiKey")
    check(!json.contains("refreshToken"), "el export no contiene refreshToken")
} catch {
    check(false, "ida y vuelta del export: \(error)")
}

let state = PersistedState(
    settings: AppSettings(menuBarMode: .compact),
    snapshots: [
        "copilot": ProviderSnapshot(
            provider: .copilot,
            planName: "Business",
            status: .ok,
            windows: [QuotaWindow(id: "premium", label: "Premium", usedPercent: 10)]
        )
    ],
    lastRefresh: exportDate
)

do {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(state)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PersistedState.self, from: data)

    checkEqual(decoded.settings.menuBarMode, .compact, "modo de barra persistido")
    checkEqual(decoded.snapshots["copilot"]?.planName, "Business", "plan persistido")
    checkEqual(decoded.snapshots["copilot"]?.windows.first?.usedPercent, 10, "cuota persistida")
} catch {
    check(false, "ida y vuelta del estado: \(error)")
}

let catalogState = PersistedState(
    settings: AppSettings(),
    lastRefresh: exportDate,
    catalog: ModelCatalog(
        fetchedAt: exportDate,
        models: [
            CatalogModel(
                modelID: "claude-opus-5-5",
                name: "Claude Opus 5.5",
                provider: .claude,
                inputPerMillion: 4,
                outputPerMillion: 20,
                cacheReadPerMillion: 0.2,
                cacheWritePerMillion: 5,
                contextWindow: 1_000_000
            )
        ]
    )
)

do {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(catalogState)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PersistedState.self, from: data)

    checkEqual(decoded.catalog?.models.count, 1, "catálogo persistido")
    checkEqual(decoded.catalog?.models.first?.modelID, "claude-opus-5-5", "id de modelo persistido")
    checkClose(decoded.catalog?.models.first?.inputPerMillion ?? 0, 4, "precio del catálogo persistido")
} catch {
    check(false, "ida y vuelta del catálogo: \(error)")
}

// MARK: - Resultado

print("")
if failures == 0 {
    print("✓ \(totalChecks) comprobaciones correctas")
    exit(0)
} else {
    print("✗ \(failures) de \(totalChecks) comprobaciones fallaron")
    exit(1)
}
