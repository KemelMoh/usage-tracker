import SwiftUI
import Charts
import UsageTrackerCore

enum DashboardTab: String, CaseIterable, Identifiable, Hashable {
    case overview
    case history
    case models
    case subscriptions
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Resumen"
        case .history: return "Historial"
        case .models: return "Modelos"
        case .subscriptions: return "Suscripciones"
        case .settings: return "Ajustes"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .history: return "chart.bar.xaxis"
        case .models: return "square.stack.3d.up"
        case .subscriptions: return "creditcard"
        case .settings: return "gearshape"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.dashboardTab) {
                    Section("Usage Tracker") {
                        ForEach(DashboardTab.allCases) { item in
                            Label(item.title, systemImage: item.symbol)
                                .tag(item)
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()
                sidebarFooter
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            Group {
                switch model.dashboardTab {
                case .overview:
                    OverviewView(model: model)
                case .history:
                    HistoryView(model: model)
                case .models:
                    ModelsCatalogView(model: model, compact: false)
                case .subscriptions:
                    SubscriptionsView(model: model)
                case .settings:
                    SettingsView(model: model)
                }
            }
            .frame(minWidth: 720, minHeight: 540)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationTitle("Usage Tracker")
        .onAppear {
            model.refreshIfNeeded()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .help("Actualizar ahora")
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(model.activeProviders.count) proveedores activos")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Usage Tracker \(model.appVersion)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let error = model.lastError {
                    ErrorBanner(message: error, onDismiss: model.clearError)
                }

                MetricCard(
                    title: "Valor de uso",
                    value: Format.money(model.totalUsageValue, settings: model.settings),
                    subtitle: "estimado, no facturado",
                    symbol: "chart.line.uptrend.xyaxis",
                    color: .green
                )

                SectionHeader(title: "Proveedores", subtitle: "Cuota actual y previsión")

                if model.activeProviders.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "switch.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No hay proveedores activos")
                                .font(.callout.weight(.semibold))
                            Text("Actívalos desde Suscripciones o desde el engranaje del panel.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .card(padding: 14)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(model.activeProviders) { provider in
                            if let snapshot = model.snapshots[provider] {
                                ProviderCard(
                                    snapshot: snapshot,
                                    subscription: model.subscription(for: provider),
                                    settings: model.settings,
                                    isStale: model.isStale(snapshot),
                                    clock: model.clock,
                                    compact: false,
                                    showModels: true
                                )
                            } else {
                                LoadingCard(provider: provider)
                            }
                        }
                    }
                }

                SectionHeader(title: "Valor de uso", subtitle: "Últimos 30 días")
                ValueSummaryCard(model: model)

                HStack(alignment: .firstTextBaseline) {
                    Text("Alertas")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    if !model.visibleAlerts.isEmpty {
                        Button("Limpiar todas") {
                            model.clearVisibleAlerts()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }

                if model.visibleAlerts.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Sin alertas activas. Todo dentro de los umbrales.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .card(padding: 14)
                } else {
                    VStack(spacing: 8) {
                        ForEach(model.visibleAlerts.suffix(6)) { alert in
                            AlertRow(alert: alert, clock: model.clock) {
                                model.dismissAlert(alert)
                            }
                        }
                    }
                }

                Text("El valor de uso de Claude y OpenCode se estima a partir de tokens y precios públicos, en los últimos 30 días. En Copilot son los AI credits consumidos en el ciclo de cuota actual, a 0,01 $ cada uno. En LiteLLM es el gasto real del portal de cuenta.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Resumen")
                    .font(.largeTitle.weight(.bold))
                Text(model.lastRefreshText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

struct ValueSummaryCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let values = model.usageValues
        return VStack(alignment: .leading, spacing: 10) {
            if !model.settings.showEstimates {
                Text("Las estimaciones están desactivadas en Ajustes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.activeProviders.isEmpty {
                Text("No hay proveedores activos.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.activeProviders) { provider in
                    HStack(spacing: 8) {
                        ProviderIcon(provider: provider, size: 24)
                        Text(provider.displayName)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(Format.money(values[provider] ?? 0, settings: model.settings))
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                    }

                    if provider != model.activeProviders.last {
                        Divider()
                            .padding(.leading, 32)
                    }
                }

                Divider()
                    .padding(.top, 2)

                Text("Claude y OpenCode: tokens × tarifas de models.dev, últimos 30 días. Copilot: AI credits × 0,01 $, consumed en el ciclo de cuota actual.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 16)
    }
}

// MARK: - History

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var provider: ProviderID = .claude
    @State private var range: Int = 30

    /// Datos ya filtrados y agregados para la pasada de render actual.
    ///
    /// Antes `filtered` era una propiedad calculada a la que se accedía seis o
    /// siete veces por render, y cada acceso reordenaba el historial entero.
    private var summary: HistorySummary {
        guard model.activeProviders.contains(provider) else { return .empty }
        let cutoff = DateUtils.daysAgo(range)
        let entries = (model.history[provider] ?? [])
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }

        var totalTokens = 0
        var totalCost = 0.0
        var aggregate: [String: ModelUsage] = [:]
        for day in entries {
            totalTokens += day.tokens.total
            totalCost += day.costUSD ?? 0
            for usage in day.models {
                var current = aggregate[usage.model] ?? ModelUsage(
                    model: usage.model,
                    tokens: .zero,
                    costUSD: 0
                )
                current.tokens += usage.tokens
                current.costUSD = (current.costUSD ?? 0) + (usage.costUSD ?? 0)
                aggregate[usage.model] = current
            }
        }

        let models = aggregate.values.sorted {
            if ($0.costUSD ?? 0) != ($1.costUSD ?? 0) {
                return ($0.costUSD ?? 0) > ($1.costUSD ?? 0)
            }
            return $0.tokens.total > $1.tokens.total
        }

        return HistorySummary(
            entries: entries,
            totalTokens: totalTokens,
            totalCost: totalCost,
            models: models
        )
    }

    var body: some View {
        let summary = summary
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Historial")
                            .font(.largeTitle.weight(.bold))
                        Text("Actividad diaria por proveedor")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Picker("Proveedor", selection: $provider) {
                        ForEach(model.activeProviders) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 430)
                    .onAppear {
                        if !model.activeProviders.contains(provider) {
                            provider = model.activeProviders.first ?? .claude
                        }
                    }
                    .onChange(of: model.activeProviders) { providers in
                        if !providers.contains(provider) {
                            provider = providers.first ?? .claude
                        }
                    }

                    Spacer()

                    Picker("Rango", selection: $range) {
                        Text("7 días").tag(7)
                        Text("30 días").tag(30)
                        Text("90 días").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                }

                if summary.entries.isEmpty {
                    EmptyState(
                        symbol: "chart.bar.xaxis",
                        title: "Sin historial todavía",
                        message: model.activeProviders.isEmpty
                            ? "No hay proveedores activos. Actívalos desde Suscripciones o desde el engranaje del panel."
                            : (provider == .copilot
                                ? "Copilot no expone historial por usuario. Usage Tracker irá construyendo el de AI credits en cada actualización."
                                : "No hay datos en el rango seleccionado.")
                    )
                    .card()
                } else {
                    chartCard(summary)
                    modelBreakdownCard(summary)
                }
            }
            .padding(24)
        }
    }

    private func chartCard(_ summary: HistorySummary) -> some View {
        let filtered = summary.entries
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider == .copilot
                         ? "AI credits por día"
                         : (provider == .liteLLM ? "Tokens por día · LiteLLM" : "Tokens por día"))
                        .font(.headline)
                    Text("\(filtered.count) días con datos")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if provider != .copilot {
                    Text("\(Format.tokens(summary.totalTokens)) tokens · \(Format.money(summary.totalCost, settings: model.settings))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if provider == .copilot {
                Chart(filtered) { item in
                    BarMark(
                        x: .value("Día", item.date, unit: .day),
                        y: .value("AI credits", item.creditsUsed ?? 0)
                    )
                    .foregroundStyle(provider.color.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading)
                }
                .frame(height: 230)
            } else {
                Chart(filtered) { item in
                    BarMark(
                        x: .value("Día", item.date, unit: .day),
                        y: .value("Tokens", item.tokens.total)
                    )
                    .foregroundStyle(provider.color.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 230)
            }

            if provider != .copilot {
                Divider()
                Text("Coste estimado por día")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Chart(filtered) { item in
                    AreaMark(
                        x: .value("Día", item.date, unit: .day),
                        y: .value("Coste", item.costUSD ?? 0)
                    )
                    .foregroundStyle(provider.color.opacity(0.18).gradient)

                    LineMark(
                        x: .value("Día", item.date, unit: .day),
                        y: .value("Coste", item.costUSD ?? 0)
                    )
                    .foregroundStyle(provider.color)
                    .interpolationMethod(.monotone)
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 6)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading) {
                        AxisGridLine()
                        AxisValueLabel()
                    }
                }
                .frame(height: 170)
            }
        }
        .card(padding: 18)
    }

    private func modelBreakdownCard(_ summary: HistorySummary) -> some View {
        let aggregates = provider == .liteLLM
            ? (model.snapshots[.liteLLM]?.models ?? summary.models)
            : summary.models
        return VStack(alignment: .leading, spacing: 12) {
            Text("Modelos")
                .font(.headline)
            Text(provider == .liteLLM
                 ? "Gasto y tokens reales según LiteLLM (últimos 120 días)"
                 : "Tokens y coste estimado en el rango seleccionado")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if aggregates.isEmpty {
                Text(provider == .copilot
                     ? "Copilot no expone desglose por modelo en la API de cuota."
                     : "Sin desglose por modelo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                let maxTokens = max(1, aggregates.map(\.tokens.total).max() ?? 1)
                ForEach(aggregates.prefix(10)) { usage in
                    VStack(spacing: 4) {
                        HStack(spacing: 8) {
                            Text(usage.model)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(Format.tokens(usage.tokens.total))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if let cost = usage.costUSD, cost > 0 {
                                Text(Format.money(cost, settings: model.settings))
                                    .font(.caption2)
                                    .monospacedDigit()
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 64, alignment: .trailing)
                            }
                        }
                        ProgressBar(
                            value: Double(usage.tokens.total) / Double(maxTokens) * 100,
                            color: provider.color,
                            height: 4
                        )
                    }
                }
            }
        }
        .card(padding: 18)
    }
}

/// Datos del historial ya filtrados y agregados para una pasada de render.
struct HistorySummary {
    let entries: [DailyUsage]
    let totalTokens: Int
    let totalCost: Double
    let models: [ModelUsage]

    static let empty = HistorySummary(
        entries: [],
        totalTokens: 0,
        totalCost: 0,
        models: []
    )
}

// MARK: - Subscriptions

struct SubscriptionsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Suscripciones")
                        .font(.largeTitle.weight(.bold))
                    Text("Estado y fecha de renovación de cada proveedor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(ProviderID.allCases) { provider in
                    if let index = model.settings.subscriptions.firstIndex(where: { $0.id == provider }) {
                        SubscriptionEditor(
                            model: model,
                            provider: provider,
                            subscription: $model.settings.subscriptions[index]
                        )
                    }
                }
            }
            .padding(24)
        }
    }
}

struct SubscriptionEditor: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID
    @Binding var subscription: Subscription

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.headline)
                    Text(provider.credentialHint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Toggle("Activa", isOn: $subscription.isActive)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Fecha de renovación")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Toggle("", isOn: Binding(
                        get: { subscription.renewalDate != nil },
                        set: { enabled in
                            subscription.renewalDate = enabled
                                ? (subscription.renewalDate ?? Date())
                                : nil
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)

                    if subscription.renewalDate != nil {
                        DatePicker(
                            "",
                            selection: Binding(
                                get: { subscription.renewalDate ?? Date() },
                                set: { subscription.renewalDate = $0 }
                            ),
                            displayedComponents: .date
                        )
                        .labelsHidden()
                    } else {
                        Text("Sin fecha")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }

                Toggle("Actualizar la fecha automáticamente con los datos del proveedor", isOn: $subscription.autoRenewal)
                    .font(.caption2)
                    .toggleStyle(.checkbox)
            }

            Divider()

            if provider == .liteLLM {
                LiteLLMSSOSection(model: model)
                Divider()
            }

            SubscriptionCredentialEditor(model: model, provider: provider)
        }
        .card(padding: 18)
    }
}

struct LiteLLMSSOSection: View {
    @ObservedObject var model: AppModel

    private var statusColor: Color {
        switch model.liteLLMSSOStatus {
        case .signedIn: return .green
        case .needsLogin: return .orange
        case .signingIn: return .blue
        case .unknown, .signedOut: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(statusColor)
                Text("Inicio de sesión de LiteLLM (SSO)")
                    .font(.caption.weight(.medium))
                Spacer()
                Text(model.liteLLMSSOStatus.label)
                    .font(.caption2)
                    .foregroundStyle(statusColor)
            }

            Text("El SSO proporciona el nivel del presupuesto, la fecha de renovación y el historial de uso. La sesión se guarda en WebKit de forma local; la clave del proxy sigue disponible como alternativa.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(model.liteLLMSSOStatus == .signingIn ? "Abriendo…" : "Iniciar sesión SSO") {
                    model.signInLiteLLM()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.liteLLMSSOStatus == .signingIn)

                if model.liteLLMSSOStatus == .signedIn || model.liteLLMSSOStatus == .needsLogin {
                    Button("Cerrar sesión") {
                        model.signOutLiteLLM()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }
}

struct SubscriptionCredentialEditor: View {
    @ObservedObject var model: AppModel
    let provider: ProviderID

    @State private var draft = ""
    @State private var testResult: String?
    @State private var isTesting = false

    private var status: CredentialStatus {
        model.credentialStatus[provider] ?? .missing
    }

    private var statusColor: Color {
        switch status {
        case .detected: return .green
        case .manual: return .blue
        case .missing: return .secondary
        case .expired: return .orange
        case .notRequired: return .secondary
        case .disabled: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Credencial")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Tag(text: status.label, color: statusColor)
            }

            if status == .disabled {
                Text("Proveedor desactivado: no se consulta esta credencial.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                SecureField("Pega una clave para sustituir la detectada", text: $draft)
                    .textFieldStyle(.roundedBorder)

                Button("Guardar") {
                    do {
                        try model.setCredential(provider: provider, value: draft)
                        draft = ""
                        testResult = "Clave guardada en el Keychain."
                    } catch {
                        testResult = error.localizedDescription
                    }
                }
                .controlSize(.small)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Borrar") {
                    model.clearCredential(provider: provider)
                    testResult = "Clave manual eliminada."
                }
                .controlSize(.small)
                .disabled(status != .manual && status != .disabled)

                Button(isTesting ? "Probando…" : "Probar") {
                    Task {
                        isTesting = true
                        testResult = await model.testConnection(provider: provider)
                        isTesting = false
                    }
                }
                .controlSize(.small)
                .disabled(isTesting || status == .disabled)
            }

            HStack(spacing: 8) {
                if let testResult {
                    Text(testResult)
                        .font(.caption2)
                        .foregroundStyle(testResult.localizedCaseInsensitiveContains("correcta") ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if status == .expired {
                    Button("Copiar comando `claude`") {
                        model.copyToPasteboard("claude")
                    }
                    .controlSize(.small)
                }

                if provider == .copilot && status == .missing {
                    Button("Copiar `gh auth login`") {
                        model.copyToPasteboard("gh auth login")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}
