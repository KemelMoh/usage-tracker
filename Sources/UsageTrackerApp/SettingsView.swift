import SwiftUI
import UsageTrackerCore

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var showReset = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ajustes")
                        .font(.largeTitle.weight(.bold))
                    Text("Comportamiento, alertas y datos locales")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = model.lastError {
                    ErrorBanner(message: error, onDismiss: model.clearError)
                }

                general
                alerts
                data
                updates
                about
            }
            .padding(24)
        }
        .alert("Borrar todos los datos", isPresented: $showReset) {
            Button("Cancelar", role: .cancel) {}
            Button("Borrar", role: .destructive) {
                model.resetAll()
            }
        } message: {
            Text("Se eliminarán ajustes, historial, alertas, claves manuales y la sesión SSO de LiteLLM. La sesión de Claude Code no se toca.")
        }
    }

    private var general: some View {
        SettingsSection(title: "General", subtitle: "Refresco y apariencia") {
            Picker("Refrescar cada", selection: $model.settings.refreshMinutes) {
                Text("1 minuto").tag(1)
                Text("5 minutos").tag(5)
                Text("15 minutos").tag(15)
                Text("30 minutos").tag(30)
                Text("60 minutos").tag(60)
            }
            .frame(maxWidth: 320, alignment: .leading)

            Picker("Barra de menús", selection: $model.settings.menuBarMode) {
                ForEach(MenuBarMode.selectableCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Picker("Moneda", selection: $model.settings.currency) {
                ForEach(Currency.allCases) { currency in
                    Text(currency.label).tag(currency)
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            Toggle("Abrir al iniciar sesión", isOn: Binding(
                get: { model.settings.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            Toggle("Mostrar valor de uso estimado", isOn: $model.settings.showEstimates)

            Toggle("Recomendaciones de modelos (beta)", isOn: $model.modelRecommendationsEnabled)
            Text("Sugerencias por contexto, recencia y precio. Modelos con tarifa de los últimos 6 meses y no deprecated; los gratuitos solo se excluyen en OpenCode Go por su política de uso de datos.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alerts: some View {
        SettingsSection(title: "Alertas", subtitle: "Avisos locales al acercarte al límite") {
            Toggle("Activar alertas", isOn: $model.settings.alertsEnabled)

            HStack(spacing: 18) {
                ThresholdToggle(threshold: 75, thresholds: $model.settings.alertThresholds)
                ThresholdToggle(threshold: 90, thresholds: $model.settings.alertThresholds)
                ThresholdToggle(threshold: 100, thresholds: $model.settings.alertThresholds)
            }
            .disabled(!model.settings.alertsEnabled)

            HStack(spacing: 10) {
                Button("Permitir notificaciones") {
                    Task { await model.requestNotifications() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Si macOS las bloquea, se usará un aviso del sistema como respaldo.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var data: some View {
        SettingsSection(title: "Datos", subtitle: "Todo se guarda en tu Mac") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Archivo de estado")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(StateStore.fileURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Abrir carpeta") {
                    model.openDataFolder()
                }
                Button("Exportar datos") {
                    model.exportData()
                }
                Button("Importar datos") {
                    model.importData()
                }
                Spacer()
                Button("Borrar todos los datos", role: .destructive) {
                    showReset = true
                }
            }
            .controlSize(.small)

            Text("El export incluye ajustes, historial y alertas. No incluye claves ni tokens.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var updates: some View {
        SettingsSection(
            title: "Actualizaciones",
            subtitle: "Versión instalada \(model.appVersion)"
        ) {
            if let update = model.availableUpdate {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                        Text("Nueva versión \(update.version)")
                            .font(.headline)
                        Spacer()
                    }

                    if !update.notes.isEmpty {
                        Text(update.notes)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button {
                            Task { await model.downloadUpdate(update) }
                        } label: {
                            if model.isDownloadingUpdate {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label("Descargar DMG", systemImage: "arrow.down.circle")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isDownloadingUpdate)
                        .help("Descarga el DMG y cierra Usage Tracker para montarlo")

                        Link("Ver release", destination: update.pageURL)
                            .font(.caption)
                            .buttonStyle(.link)

                        Spacer()

                        Button("Ignorar") {
                            model.dismissUpdate()
                        }
                        .font(.caption)
                        .buttonStyle(.link)
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Text(lastUpdateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        Task { await model.checkForUpdates() }
                    } label: {
                        if model.isCheckingForUpdates {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Buscar actualizaciones", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isCheckingForUpdates)
                }
            }

            if let error = model.updateError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Al descargar el DMG, Usage Tracker se cierra y lo abre automáticamente. La instalación sigue siendo manual: arrastra la app nueva a Aplicaciones.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastUpdateText: String {
        guard let last = model.lastUpdateCheck else {
            return "Aún no se ha comprobado."
        }
        return "Última comprobación: \(Format.relative(last, now: model.clock.now))"
    }

    private var about: some View {
        SettingsSection(title: "Acerca de Usage Tracker", subtitle: "Versión \(model.appVersion)") {
            Text("Usage Tracker centraliza el uso de OpenCode Go, GitHub Copilot, Claude y LiteLLM en la barra de menús de macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Sin backend, sin telemetría y sin sincronización propia en nube. Los endpoints de LiteLLM se inyectan desde la configuración privada de build. Los demás hosts de red se limitan a opencode.ai, api.github.com, api.anthropic.com, models.dev, github.com, objects.githubusercontent.com y release-assets.githubusercontent.com. El SSO se conserva en el almacén WebKit de esta app; las demás credenciales se leen del Keychain o de las herramientas locales y se mantienen en memoria durante la petición.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("El plan y el precio se detectan automáticamente cuando el proveedor lo expone (Claude, Copilot y LiteLLM). OpenCode Go no publica el plan en su API, así que se asume Go y puedes cambiarlo. El catálogo de modelos combina OpenCode Go, los deployments/precios públicos del proxy LiteLLM y metadatos de models.dev; se cachea 24 horas.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("El historial de Claude se calcula localmente a partir de ~/.claude/stats-cache.json y de las transcripciones de sesiones. El de OpenCode, de su base SQLite en modo solo lectura. No se lee el contenido de los mensajes, solo los campos de uso.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .card(padding: 18)
    }
}

struct ThresholdToggle: View {
    let threshold: Double
    @Binding var thresholds: [Double]

    var body: some View {
        Toggle("Avisar al \(Int(threshold))%", isOn: Binding(
            get: { thresholds.contains(threshold) },
            set: { enabled in
                if enabled {
                    if !thresholds.contains(threshold) {
                        thresholds.append(threshold)
                        thresholds.sort()
                    }
                } else {
                    thresholds.removeAll { $0 == threshold }
                }
            }
        ))
        .toggleStyle(.checkbox)
        .font(.caption)
    }
}
