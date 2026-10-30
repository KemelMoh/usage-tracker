import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers
import UsageTrackerCore

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            if oldValue.refreshMinutes != settings.refreshMinutes {
                configureTimer()
            }
            let wasActive = Set(oldValue.subscriptions.filter(\.isActive).map(\.id))
            let nowActive = settings.activeProviderIDs
            let deactivated = wasActive.subtracting(nowActive)
            if !deactivated.isEmpty {
                for provider in deactivated {
                    credentialStatus[provider] = .disabled
                }
            }
            let activated = nowActive.subtracting(wasActive)
            if !activated.isEmpty {
                for provider in activated where credentialStatus[provider] == .disabled {
                    credentialStatus[provider] = .missing
                }
                // Al reactivar un proveedor se refresca en cuanto termine el
                // refresco en curso, para no mostrar datos antiguos.
                Task { await refreshAfterActivation() }
            }
            scheduleSave()
        }
    }

    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var history: [ProviderID: [DailyUsage]] = [:]
    @Published private(set) var alerts: [AppAlert] = []
    @Published private(set) var credentialStatus: [ProviderID: CredentialStatus] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var modelCatalog: ModelCatalog?
    @Published private(set) var isCatalogLoading = false
    @Published private(set) var catalogError: String?
    @Published private(set) var catalogLastAttempt: Date?
    @Published private(set) var liteLLMSSOStatus: LiteLLMSSOStatus = .unknown
    /// Recomendaciones ya calculadas para el catálogo actual. Se rehacen solo
    /// cuando cambia el catálogo, no en cada pasada de render de la interfaz.
    @Published private(set) var recommendationIndex: RecommendationIndex = .empty
    @Published var lastError: String?
    @Published var dashboardTab: DashboardTab = .overview
    @Published var modelRecommendationsEnabled: Bool = false {
        didSet {
            guard modelRecommendationsEnabled != oldValue else { return }
            UserDefaults.standard.set(
                modelRecommendationsEnabled,
                forKey: Self.modelRecommendationsKey
            )
            rebuildRecommendationIndex()
        }
    }
    @Published private(set) var availableUpdate: AppUpdate?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isDownloadingUpdate = false
    @Published private(set) var lastUpdateCheck: Date?
    @Published var updateError: String?

    private static let modelRecommendationsKey = "modelRecommendationsEnabled"
    private static let lastUpdateCheckKey = "lastUpdateCheck"

    /// Reloj de la interfaz. Vive fuera de `AppModel` para que sus tics no
    /// invaliden las vistas que no muestran tiempos.
    let clock = Clock()

    private var alertKeys: [String: Date] = [:]
    private var timer: Timer?
    private var saveWorkItem: DispatchWorkItem?
    private let liteLLMSession = LiteLLMSession()

    init() {
        let state = StateStore.load()
        self.settings = state.settings
        self.modelRecommendationsEnabled = UserDefaults.standard
            .object(forKey: Self.modelRecommendationsKey) as? Bool ?? false
        self.lastUpdateCheck = UserDefaults.standard
            .object(forKey: Self.lastUpdateCheckKey) as? Date
        self.snapshots = Self.decodeSnapshots(state.snapshots)
        self.history = Self.decodeHistory(state.history)
        self.alerts = state.alerts
        self.alertKeys = state.alertKeys
        self.lastRefresh = state.lastRefresh
        self.modelCatalog = state.catalog.map { catalog in
            ModelCatalog(
                fetchedAt: catalog.fetchedAt,
                models: ModelCatalogService.sorted(catalog.models),
                sourceVersion: catalog.sourceVersion
            )
        }
        self.recommendationIndex = modelRecommendationsEnabled
            ? RecommendationIndex.build(from: catalogModels, now: clock.now)
            : .empty

        self.settings.launchAtLogin = SMAppService.mainApp.status == .enabled

        configureTimer()

        Task { await refresh() }
        Task { await checkForUpdatesIfNeeded() }

        if settings.alertsEnabled {
            Task { _ = await NotificationService.requestPermission() }
        }
    }

    // MARK: - Public computed state

    var now: Date { clock.now }

    var activeSubscriptions: [Subscription] {
        settings.activeSubscriptions
    }

    /// Proveedores visibles en Uso, barra de menús y alertas.
    var activeProviders: [ProviderID] {
        ProviderID.allCases.filter { subscription(for: $0).isActive }
    }

    var visibleAlerts: [AppAlert] {
        let active = Set(activeProviders)
        return alerts.filter { active.contains($0.provider) }
    }

    var worstPercent: Double? {
        activeProviders.compactMap { snapshots[$0]?.worstPercent }.max()
    }

    var menuBarText: String {
        switch settings.menuBarMode {
        case .iconOnly:
            return ""
        case .worstPercent:
            guard let worstPercent else { return "—" }
            return "\(Int(worstPercent.rounded()))%"
        case .compact:
            return activeProviders.map { provider in
                let value = snapshots[provider]?.worstPercent
                return "\(provider.shortName) \(value.map { "\(Int($0.rounded()))" } ?? "—")"
            }.joined(separator: " · ")
        case .monthlyCost:
            // Modo heredado: ya no se muestra coste mensual en la barra.
            return ""
        }
    }

    var menuBarColor: Color {
        Theme.statusColor(for: worstPercent)
    }

    var lastRefreshText: String {
        guard let lastRefresh else { return "Sin actualizar" }
        return "Actualizado \(Format.relative(lastRefresh, now: clock.now))"
    }

    var catalogUpdatedText: String {
        guard let fetchedAt = modelCatalog?.fetchedAt else { return "Modelos sin cargar" }
        return "Modelos \(Format.relative(fetchedAt, now: clock.now))"
    }

    var catalogIsStale: Bool {
        guard let fetchedAt = modelCatalog?.fetchedAt else { return true }
        return clock.now.timeIntervalSince(fetchedAt) > 24 * 3_600
    }

    private var catalogNeedsMetadata: Bool {
        guard let models = modelCatalog?.models, !models.isEmpty else { return false }
        return models.allSatisfy { $0.releaseDate == nil && $0.lastUpdated == nil }
    }

    private var catalogNeedsLiteLLMModels: Bool {
        guard let models = modelCatalog?.models else { return true }
        return !models.contains(where: { $0.provider == .liteLLM })
    }

    private var catalogNeedsEnrichment: Bool {
        modelCatalog?.sourceVersion != ModelCatalog.currentSourceVersion
    }

    var catalogModels: [CatalogModel] {
        modelCatalog?.models ?? []
    }

    /// Recalcula las recomendaciones del catálogo. Solo hace falta cuando
    /// cambia el catálogo o se activa/desactiva la función.
    func rebuildRecommendationIndex() {
        guard modelRecommendationsEnabled else {
            if recommendationIndex.byProvider.isEmpty { return }
            recommendationIndex = .empty
            return
        }
        recommendationIndex = RecommendationIndex.build(from: catalogModels, now: clock.now)
    }

    func subscription(for provider: ProviderID) -> Subscription {
        settings.subscription(for: provider) ?? .default(for: provider)
    }

    func applyDetectedPlan(_ provider: ProviderID, planName: String) {
        guard provider.supportsPlanDetection,
              let option = provider.planOption(named: planName),
              let index = settings.subscriptions.firstIndex(where: { $0.id == provider }),
              settings.subscriptions[index].priceSource == .auto else {
            return
        }

        var subscription = settings.subscriptions[index]
        guard subscription.planName != option.name
                || abs(subscription.monthlyPriceUSD - option.priceUSD) > 0.001 else {
            return
        }
        subscription.planName = option.name
        subscription.monthlyPriceUSD = option.priceUSD
        settings.subscriptions[index] = subscription
    }

    func isStale(_ snapshot: ProviderSnapshot) -> Bool {
        let threshold = TimeInterval(max(10, settings.refreshMinutes * 60 * 2))
        return Date().timeIntervalSince(snapshot.fetchedAt) > threshold
    }

    func usageValue(for provider: ProviderID) -> Double {
        if provider == .copilot {
            // El acumulado de AI credits del ciclo es el unico dato fiable
            // del consumo. El historial diario solo se llena desde que la app
            // esta abierta, asi que no sirve para el valor de uso.
            return CopilotHistoryMerger.usageValue(snapshot: snapshots[.copilot])
        }

        let cutoff = DateUtils.monthsAgo(1)
        return (history[provider] ?? [])
            .filter { $0.date >= cutoff }
            .compactMap(\.costUSD)
            .reduce(0, +)
    }

    /// Valor de uso por proveedor en una sola pasada sobre el historial.
    ///
    /// `usageValue(for:)` filtra el historial entero por cada proveedor, y
    /// llamarlo para los tres providers repetía ese trabajo tres veces por
    /// cada render del resumen.
    var usageValues: [ProviderID: Double] {
        let cutoff = DateUtils.monthsAgo(1)
        var values: [ProviderID: Double] = [:]

        values[.copilot] = CopilotHistoryMerger.usageValue(snapshot: snapshots[.copilot])

        for (provider, entries) in history where provider != .copilot {
            var total = 0.0
            for entry in entries where entry.date >= cutoff {
                total += entry.costUSD ?? 0
            }
            values[provider] = total
        }
        return values
    }

    var totalUsageValue: Double {
        let values = usageValues
        return ProviderID.allCases
            .filter { subscription(for: $0).isActive }
            .reduce(0) { $0 + (values[$1] ?? 0) }
    }

    func alerts(for provider: ProviderID) -> [AppAlert] {
        guard subscription(for: provider).isActive else { return [] }
        return alerts.filter { $0.provider == provider }
    }

    func dismissAlert(_ alert: AppAlert) {
        alerts.removeAll { $0.id == alert.id }
        persist()
    }

    func clearVisibleAlerts() {
        let active = Set(activeProviders)
        alerts.removeAll { active.contains($0.provider) }
        persist()
    }

    // MARK: - Updates

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2.4"
    }

    func checkForUpdatesIfNeeded() async {
        guard availableUpdate == nil else { return }
        if let lastUpdateCheck,
           Date().timeIntervalSince(lastUpdateCheck) < 24 * 3_600 {
            return
        }
        await checkForUpdates(silent: true)
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        do {
            if let latest = try await UpdateChecker.latest(),
               UpdateChecker.isNewer(latest.version, than: appVersion) {
                availableUpdate = latest
                updateError = nil
            } else {
                availableUpdate = nil
                updateError = nil
            }
            lastUpdateCheck = Date()
            UserDefaults.standard.set(lastUpdateCheck, forKey: Self.lastUpdateCheckKey)
        } catch {
            if !silent {
                updateError = "No se pudo comprobar la actualización: \(error.localizedDescription)"
            }
        }
    }

    func downloadUpdate(_ update: AppUpdate) async {
        guard !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        defer { isDownloadingUpdate = false }

        do {
            let (data, _) = try await HTTPClient.shared.get(
                url: update.dmgURL,
                headers: [
                    "Accept": "application/octet-stream",
                    "User-Agent": "UsageTracker/0.1"
                ]
            )
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let destination = downloads.appendingPathComponent(update.dmgURL.lastPathComponent)
            try data.write(to: destination, options: .atomic)
            updateError = nil

            // La app se cierra para que el DMG pueda montarse sobre
            // /Applications: arrastrar la app nueva encima no funciona si la
            // vieja sigue en ejecución.
            openUpdateInstaller(at: destination)
            quitForUpdate()
        } catch {
            updateError = "No se pudo descargar el DMG: \(error.localizedDescription)"
        }
    }

    /// Abre el DMG una vez que la app haya terminado.
    ///
    /// El proceso auxiliar espera al PID exacto de esta app, no al nombre del
    /// proceso: así no se queda colgado si hay otra instancia o una app con el
    /// mismo nombre. En macOS, un hijo sobrevive a la muerte de su padre, así
    /// que el auxiliar sigue vivo aunque la app se cierre.
    private func openUpdateInstaller(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        // La ruta se pasa como argumento y no interpolada en el script, para
        // que un nombre de archivo raro no rompa la llamada.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do
            /bin/sleep 0.2
        done
        /usr/bin/open "$2"
        """

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "sh", String(pid), url.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        helper.standardInput = FileHandle.nullDevice

        do {
            try helper.run()
        } catch {
            // Si no se puede lanzar el auxiliar, se abre igualmente: el
            // usuario podrá montarlo a mano.
            NSWorkspace.shared.open(url)
        }
    }

    /// Cierra la app para que el DMG pueda montarse sobre la instalación
    /// actual.
    private func quitForUpdate() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func dismissUpdate() {
        availableUpdate = nil
    }

    func clearUpdateError() {
        updateError = nil
    }

    // MARK: - Refresh

    func refreshIfNeeded() {
        guard let lastRefresh else {
            Task { await refresh() }
            return
        }
        let interval = TimeInterval(max(AppSettings.minimumRefreshMinutes, settings.refreshMinutes) * 60)
        if Date().timeIntervalSince(lastRefresh) > interval {
            Task { await refresh() }
        }
    }

    private func refreshAfterActivation() async {
        while isRefreshing {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        await refresh()
    }

    func refreshCatalog() async {
        await refreshCatalogIfNeeded(force: true)
    }

    func refreshCatalogIfNeeded(force: Bool = false) async {
        guard !isCatalogLoading else { return }

        if !force {
            if let fetchedAt = modelCatalog?.fetchedAt,
               Date().timeIntervalSince(fetchedAt) < 24 * 3_600,
               !catalogNeedsMetadata,
               !catalogNeedsLiteLLMModels,
               !catalogNeedsEnrichment {
                return
            }
            // Evita reintentar en cada refresco si el catálogo acaba de fallar.
            if let attempted = catalogLastAttempt,
               Date().timeIntervalSince(attempted) < 10 * 60 {
                return
            }
        }

        isCatalogLoading = true
        catalogLastAttempt = Date()
        defer { isCatalogLoading = false }

        do {
            let catalog = try await ModelCatalogService.fetch()
            guard !catalog.models.isEmpty else {
                throw ProviderError.decoding("El catálogo de modelos está vacío.")
            }
            modelCatalog = catalog
            catalogError = nil
            rebuildRecommendationIndex()
            persist()
        } catch {
            catalogError = "No se pudo actualizar el catálogo de modelos: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await refreshCatalogIfNeeded()

        // Solo se leen credenciales de proveedores activos. Si Claude está
        // desactivado, no se toca su elemento del Keychain ni se pide permiso.
        let activeProviders = self.activeProviders
        let activeSet = Set(activeProviders)
        var credentials = await Task.detached(priority: .userInitiated) {
            CredentialResolver.resolve(for: activeSet.subtracting([.liteLLM]))
        }.value

        let liteLLMHasSession: Bool
        if activeSet.contains(.liteLLM) {
            liteLLMHasSession = await liteLLMSession.authCookie() != nil
        } else {
            liteLLMHasSession = false
        }
        if activeSet.contains(.liteLLM) {
            if liteLLMHasSession {
                credentials.statuses[.liteLLM] = .notRequired
            } else {
                let fallbackCredential = await resolveLiteLLMCredential()
                credentials.liteLLMKey = fallbackCredential.key
                credentials.statuses[.liteLLM] = fallbackCredential.status
            }
        }
        credentialStatus = credentials.statuses

        // Claude revela el plan en su propia sesión; Copilot, en la respuesta de
        // la API. OpenCode Go no lo expone y conserva la elección del usuario.
        if activeSet.contains(.claude), let claudeDetected = credentials.claude?.inferredPlan {
            applyDetectedPlan(.claude, planName: claudeDetected)
        }

        let openCodePlan = subscription(for: .opencodeGo).planName
        let copilotPlan = subscription(for: .copilot).planName
        let claudePlan = subscription(for: .claude).planName
        let litellmPlan = subscription(for: .liteLLM).planName

        let liteLLMPlatformTask: Task<LiteLLMUsageReport, Error>?
        if liteLLMHasSession {
            liteLLMPlatformTask = Task {
                try await LiteLLMPlatformClient(authStore: liteLLMSession).report()
            }
        } else {
            liteLLMPlatformTask = nil
            if activeSet.contains(.liteLLM) {
                liteLLMSSOStatus = .signedOut
            }
        }

        var fetchedSnapshots = await withTaskGroup(of: ProviderSnapshot.self) { group in
            if activeSet.contains(.opencodeGo) {
                group.addTask {
                    await OpenCodeGoClient().fetch(
                        apiKey: credentials.openCodeKey,
                        planName: openCodePlan
                    )
                }
            }
            if activeSet.contains(.copilot) {
                group.addTask {
                    await CopilotClient().fetch(
                        token: credentials.copilotToken,
                        fallbackPlan: copilotPlan
                    )
                }
            }
            if activeSet.contains(.claude) {
                group.addTask {
                    await ClaudeClient().fetch(
                        credentials: credentials.claude,
                        fallbackPlan: claudePlan
                    )
                }
            }
            var results: [ProviderSnapshot] = []
            for await snapshot in group {
                results.append(snapshot)
            }
            return results
        }

        var liteLLMHistory: [DailyUsage] = []
        if activeSet.contains(.liteLLM) {
            if let liteLLMPlatformTask {
                do {
                    let report = try await liteLLMPlatformTask.value
                    liteLLMSSOStatus = .signedIn
                    credentials.statuses[.liteLLM] = .notRequired
                    credentialStatus[.liteLLM] = .notRequired
                    liteLLMHistory = report.daily
                    applyDetectedPlan(.liteLLM, planName: report.tier)
                    fetchedSnapshots.append(liteLLMSnapshot(from: report))
                } catch {
                    if let platformError = error as? LiteLLMPlatformError,
                       case .needsLogin = platformError {
                        liteLLMSSOStatus = .needsLogin
                    } else {
                        liteLLMSSOStatus = .signedIn
                    }
                    if credentials.liteLLMKey == nil {
                        let fallbackCredential = await resolveLiteLLMCredential()
                        credentials.liteLLMKey = fallbackCredential.key
                        credentials.statuses[.liteLLM] = fallbackCredential.status
                        credentialStatus[.liteLLM] = fallbackCredential.status
                    }
                    let proxySnapshot = await LiteLLMClient().fetch(
                        apiKey: credentials.liteLLMKey,
                        fallbackPlan: litellmPlan
                    )
                    fetchedSnapshots.append(
                        proxySnapshot.status == .ok
                            ? proxySnapshot
                            : liteLLMFailureSnapshot(error: error, fallbackPlan: litellmPlan)
                    )
                }
            } else {
                let proxySnapshot = await LiteLLMClient().fetch(
                    apiKey: credentials.liteLLMKey,
                    fallbackPlan: litellmPlan
                )
                if proxySnapshot.status == .ok {
                    fetchedSnapshots.append(proxySnapshot)
                } else {
                    fetchedSnapshots.append(liteLLMFailureSnapshot(error: nil, fallbackPlan: litellmPlan))
                }
            }
        }

        if let copilotSnapshot = fetchedSnapshots.first(where: { $0.provider == .copilot }),
           copilotSnapshot.status == .ok {
            applyDetectedPlan(.copilot, planName: copilotSnapshot.planName)
        }

        for result in fetchedSnapshots {
            var snapshot = result
            // Refleja el plan finalmente aplicado (manual o detectado).
            snapshot.planName = subscription(for: snapshot.provider).planName
            snapshots[snapshot.provider] = snapshot
            if snapshot.status == .ok {
                applyAutoRenewal(for: snapshot)
            }
        }

        let claudePrices = modelCatalog?.priceTable(for: .claude)
        let histories = await withTaskGroup(of: (ProviderID, [DailyUsage]).self) { group in
            if activeSet.contains(.claude) {
                group.addTask {
                    (.claude, ClaudeHistoryLoader.load(days: 120, prices: claudePrices))
                }
            }
            if activeSet.contains(.opencodeGo) {
                group.addTask {
                    (.opencodeGo, OpenCodeHistoryLoader.load(days: 120))
                }
            }

            var results: [(ProviderID, [DailyUsage])] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        for (provider, incoming) in histories {
            history[provider] = HistoryMerger.merge(
                existing: history[provider] ?? [],
                incoming: incoming
            )
        }

        if !liteLLMHistory.isEmpty {
            history[.liteLLM] = HistoryMerger.merge(
                existing: history[.liteLLM] ?? [],
                incoming: liteLLMHistory
            )
        }

        if activeSet.contains(.copilot),
           let copilot = snapshots[.copilot],
           copilot.status == .ok,
           let used = copilot.creditsUsed {
            appendCopilotSnapshot(used)
        }

        for provider in activeProviders {
            guard var snapshot = snapshots[provider] else { continue }
            if provider != .liteLLM || snapshot.models.isEmpty {
                snapshot.models = topModels(for: provider)
            }
            snapshots[provider] = snapshot
        }

        let evaluation = AlertEngine.evaluate(
            snapshots: snapshots,
            settings: settings,
            existingKeys: alertKeys,
            now: Date()
        )
        alertKeys = evaluation.keys

        if !evaluation.newAlerts.isEmpty {
            alerts.append(contentsOf: evaluation.newAlerts)
            alerts = Array(alerts.suffix(40))
            for alert in evaluation.newAlerts {
                NotificationService.send(alert: alert)
            }
        }

        alertKeys = alertKeys.filter { Date().timeIntervalSince($0.value) < 90 * 86_400 }
        lastRefresh = Date()
        lastError = nil
        persist()
    }

    private func applyAutoRenewal(for snapshot: ProviderSnapshot) {
        guard let index = settings.subscriptions.firstIndex(where: { $0.id == snapshot.provider }),
              settings.subscriptions[index].autoRenewal else {
            return
        }

        let windowID: String?
        switch snapshot.provider {
        case .opencodeGo: windowID = "monthly"
        case .copilot: windowID = "credits"
        case .claude: windowID = nil
        case .liteLLM: windowID = "budget"
        }

        guard let windowID,
              let date = snapshot.windows.first(where: { $0.id == windowID })?.resetsAt else {
            return
        }

        if settings.subscriptions[index].renewalDate != date {
            settings.subscriptions[index].renewalDate = date
        }
    }

    /// Guarda el punto diario de Copilot.
    ///
    /// Guarda el punto diario de Copilot.
    ///
    /// La API solo expone el acumulado de AI credits del ciclo, asi que el
    /// consumo de cada dia se obtiene restando el acumulado del dia anterior.
    /// Los dias sin consumo no se registran.
    private func appendCopilotSnapshot(_ cumulative: Double) {
        history[.copilot] = CopilotHistoryMerger.merge(
            existing: history[.copilot] ?? [],
            cumulative: cumulative
        )
    }

    private func topModels(for provider: ProviderID) -> [ModelUsage] {
        let cutoff = DateUtils.daysAgo(30)
        var aggregate: [String: ModelUsage] = [:]

        for day in (history[provider] ?? []) where day.date >= cutoff {
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

        return aggregate.values.sorted {
            if ($0.costUSD ?? 0) != ($1.costUSD ?? 0) {
                return ($0.costUSD ?? 0) > ($1.costUSD ?? 0)
            }
            return $0.tokens.total > $1.tokens.total
        }.prefix(5).map { $0 }
    }

    // MARK: - Credentials

    func setCredential(provider: ProviderID, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try KeychainStore.save(account: provider.rawValue, value: trimmed)
        credentialStatus[provider] = .manual
        Task { await refresh() }
    }

    func clearCredential(provider: ProviderID) {
        KeychainStore.delete(account: provider.rawValue)
        if provider == .liteLLM {
            KeychainStore.delete(account: ProviderID.legacyLiteLLMIdentifier)
        }
        credentialStatus[provider] = .missing
        Task { await refresh() }
    }

    func signInLiteLLM() {
        guard EndpointConfiguration.accountPortalBaseURL != nil else {
            liteLLMSSOStatus = .needsLogin
            lastError = "Falta la configuración privada del portal de cuenta LiteLLM."
            return
        }
        liteLLMSSOStatus = .signingIn
        liteLLMSession.presentLogin(onSuccess: { [weak self] in
            guard let self else { return }
            self.liteLLMSSOStatus = .signedIn
            Task { await self.refresh() }
        }, onClose: { [weak self] in
            guard let self, self.liteLLMSSOStatus == .signingIn else { return }
            Task { @MainActor in
                self.liteLLMSSOStatus = await self.liteLLMSession.authCookie() == nil
                    ? .signedOut
                    : .unknown
            }
        })
    }

    func signOutLiteLLM() {
        Task { @MainActor in
            await liteLLMSession.signOut()
            liteLLMSSOStatus = .signedOut
            if subscription(for: .liteLLM).isActive {
                await refresh()
            }
        }
    }

    func testConnection(provider: ProviderID) async -> String {
        guard subscription(for: provider).isActive else {
            return "Proveedor desactivado. Actívalo para probar la conexión."
        }
        let credentials = CredentialResolver.resolve(for: [provider])

        switch provider {
        case .opencodeGo:
            let snapshot = await OpenCodeGoClient().fetch(
                apiKey: credentials.openCodeKey,
                planName: subscription(for: .opencodeGo).planName
            )
            if snapshot.status == .ok, let monthly = snapshot.windows.first(where: { $0.id == "monthly" }) {
                return "Conexión correcta. Uso mensual: \(Format.percent(monthly.usedPercent))."
            }
            return snapshot.errorMessage ?? "No se pudo conectar."
        case .copilot:
            let snapshot = await CopilotClient().fetch(
                token: credentials.copilotToken,
                fallbackPlan: subscription(for: .copilot).planName
            )
            if snapshot.status == .ok {
                return "Conexión correcta. Plan: \(snapshot.planName)."
            }
            return snapshot.errorMessage ?? "No se pudo conectar."
        case .claude:
            let snapshot = await ClaudeClient().fetch(
                credentials: credentials.claude,
                fallbackPlan: subscription(for: .claude).planName
            )
            if snapshot.status == .ok, let window = snapshot.windows.first {
                return "Conexión correcta. \(window.label): \(Format.percent(window.usedPercent))."
            }
            return snapshot.errorMessage ?? "No se pudo conectar."
        case .liteLLM:
            if await liteLLMSession.authCookie() != nil {
                do {
                    let report = try await LiteLLMPlatformClient(authStore: liteLLMSession).report()
                    liteLLMSSOStatus = .signedIn
                    applyDetectedPlan(.liteLLM, planName: report.tier)
                    return "Conexión correcta con LiteLLM. Plan \(report.tier): \(NumberFormat.usd(report.spend)) este mes."
                } catch {
                    if let platformError = error as? LiteLLMPlatformError,
                       case .needsLogin = platformError {
                        liteLLMSSOStatus = .needsLogin
                    }
                }
            }
            let snapshot = await LiteLLMClient().fetch(
                apiKey: credentials.liteLLMKey,
                fallbackPlan: subscription(for: .liteLLM).planName
            )
            if snapshot.status == .ok, let window = snapshot.windows.first {
                if window.isUnlimited {
                    return "Conexión correcta. \(window.detail ?? "Presupuesto sin límite declarado.")."
                }
                return "Conexión correcta. \(window.label): \(Format.percent(window.usedPercent)). \(window.detail ?? "")"
            }
            return snapshot.errorMessage ?? "No se pudo conectar."
        }
    }

    private func liteLLMSnapshot(from report: LiteLLMUsageReport) -> ProviderSnapshot {
        let detail: String
        if let budget = report.budget, budget > 0 {
            detail = "\(NumberFormat.usd(report.spend)) de \(NumberFormat.usd(budget))"
        } else {
            detail = "\(NumberFormat.usd(report.spend)) este mes"
        }
        let window = QuotaWindow(
            id: "budget",
            label: "Presupuesto · mes actual",
            usedPercent: report.usedPercent,
            resetsAt: report.budgetResetAt,
            windowDuration: liteLLMWindowDuration(for: report),
            detail: detail,
            isUnlimited: report.budget == nil || report.budget == 0,
            usedValue: report.spend,
            limitValue: report.budget
        )
        return ProviderSnapshot(
            provider: .liteLLM,
            fetchedAt: report.dataUpdatedAt ?? Date(),
            planName: report.tier,
            status: .ok,
            windows: [window],
            models: report.models,
            accountLabel: report.accountLabel
        )
    }

    private func liteLLMWindowDuration(for report: LiteLLMUsageReport) -> TimeInterval {
        guard let duration = report.budgetDuration?.lowercased(), !duration.isEmpty else {
            return 30 * 86_400
        }

        let reset = report.budgetResetAt
        let calendar = Calendar.current
        if duration.hasSuffix("mo"), let months = Int(duration.dropLast(2)), months > 0 {
            if let reset,
               let start = calendar.date(byAdding: .month, value: -months, to: reset) {
                return reset.timeIntervalSince(start)
            }
            let components = calendar.dateComponents([.year, .month], from: Date())
            if let start = calendar.date(from: components),
               let end = calendar.date(byAdding: .month, value: months, to: start) {
                return end.timeIntervalSince(start)
            }
        }
        if duration.hasSuffix("d"), let days = Int(duration.dropLast()), days > 0 {
            return TimeInterval(days) * 86_400
        }
        if duration.hasSuffix("w"), let weeks = Int(duration.dropLast()), weeks > 0 {
            return TimeInterval(weeks) * 7 * 86_400
        }
        if duration.hasSuffix("h"), let hours = Int(duration.dropLast()), hours > 0 {
            return TimeInterval(hours) * 3_600
        }
        return 30 * 86_400
    }

    private func liteLLMFailureSnapshot(error: Error?, fallbackPlan: String) -> ProviderSnapshot {
        let providerError: ProviderError
        if let platformError = error as? LiteLLMPlatformError {
            switch platformError {
            case .needsLogin:
                providerError = .auth("La sesión LiteLLM requiere iniciar sesión de nuevo.")
            case .network(let message):
                providerError = .network(message)
            case .http(let status):
                providerError = .http(status, "LiteLLM")
            case .decoding(let message):
                providerError = .decoding(message)
            }
        } else {
            providerError = .missingCredential(
                "Inicia sesión en LiteLLM o configura una clave del proxy en Suscripciones."
            )
        }
        return .failure(provider: .liteLLM, planName: fallbackPlan, error: providerError)
    }

    private func resolveLiteLLMCredential() async -> (key: String?, status: CredentialStatus) {
        let resolved = await Task.detached(priority: .userInitiated) {
            CredentialResolver.resolve(for: [.liteLLM])
        }.value
        return (resolved.liteLLMKey, resolved.statuses[.liteLLM] ?? .missing)
    }

    // MARK: - System integration

    func requestNotifications() async {
        let granted = await NotificationService.requestPermission()
        if !granted {
            lastError = "Notificaciones denegadas. Actívalas en Ajustes del Sistema > Notificaciones > Usage Tracker."
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            settings.launchAtLogin = enabled
            lastError = nil
        } catch {
            settings.launchAtLogin = SMAppService.mainApp.status == .enabled
            lastError = "No se pudo cambiar el arranque automático: \(error.localizedDescription). Mueve Usage Tracker.app a /Applications y vuelve a intentarlo."
        }
    }

    func openDataFolder() {
        try? FileManager.default.createDirectory(
            at: StateStore.directoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(StateStore.directoryURL)
    }

    func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    func clearError() {
        lastError = nil
    }

    func clearCatalogError() {
        catalogError = nil
    }

    // MARK: - Data

    func exportData() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "usage-tracker-export-\(DateUtils.dayKey(Date())).json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let payload = ExportPayload(
                settings: self.settings,
                history: Dictionary(uniqueKeysWithValues: self.history.map { ($0.key.rawValue, $0.value) }),
                alerts: self.alerts
            )
            do {
                let data = try StateStore.encodeExport(payload)
                try data.write(to: url, options: .atomic)
            } catch {
                self.lastError = "No se pudo exportar: \(error.localizedDescription)"
            }
        }
    }

    func importData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let data = try Data(contentsOf: url)
                let payload = try StateStore.decodeExport(data)
                self.settings = payload.settings
                self.history = Self.decodeHistory(payload.history)
                self.alerts = payload.alerts
                self.persist()
                Task { await self.refresh() }
            } catch {
                self.lastError = "No se pudo importar: \(error.localizedDescription)"
            }
        }
    }

    func resetAll() {
        StateStore.reset()
        for provider in ProviderID.allCases {
            KeychainStore.delete(account: provider.rawValue)
        }
        KeychainStore.delete(account: ProviderID.legacyLiteLLMIdentifier)
        settings = .default
        snapshots = [:]
        history = [:]
        alerts = []
        alertKeys = [:]
        lastRefresh = nil
        credentialStatus = [:]
        modelCatalog = nil
        recommendationIndex = .empty
        catalogError = nil
        catalogLastAttempt = nil
        lastError = nil
        liteLLMSSOStatus = .signedOut
        Task {
            await liteLLMSession.signOut()
            await refresh()
        }
    }

    // MARK: - Persistence

    func persist() {
        let state = PersistedState(
            settings: settings,
            snapshots: Dictionary(uniqueKeysWithValues: snapshots.map { ($0.key.rawValue, $0.value) }),
            history: Dictionary(uniqueKeysWithValues: history.map { ($0.key.rawValue, $0.value) }),
            alertKeys: alertKeys,
            alerts: alerts,
            lastRefresh: lastRefresh,
            catalog: modelCatalog
        )
        StateStore.save(state)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.persist()
            }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    private func configureTimer() {
        timer?.invalidate()
        let interval = TimeInterval(max(AppSettings.minimumRefreshMinutes, settings.refreshMinutes) * 60)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private static func decodeSnapshots(_ raw: [String: ProviderSnapshot]) -> [ProviderID: ProviderSnapshot] {
        var result: [ProviderID: ProviderSnapshot] = [:]
        for (key, value) in raw {
            if let provider = ProviderID.persistedID(key) {
                result[provider] = value
            }
        }
        return result
    }

    private static func decodeHistory(_ raw: [String: [DailyUsage]]) -> [ProviderID: [DailyUsage]] {
        var result: [ProviderID: [DailyUsage]] = [:]
        for (key, value) in raw {
            if let provider = ProviderID.persistedID(key) {
                result[provider] = value
            }
        }
        return result
    }
}
