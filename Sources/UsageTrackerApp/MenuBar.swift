import SwiftUI
import AppKit
import UsageTrackerCore

enum PopoverTab: String, CaseIterable, Identifiable {
    case usage
    case models

    var id: String { rawValue }

    var title: String {
        switch self {
        case .usage: return "Uso"
        case .models: return "Modelos"
        }
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.settings.menuBarMode {
            case .iconOnly:
                Image(nsImage: NSApp.applicationIconImage)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            case .compact:
                if let image = MenuBarProviderImage.make(
                    providers: model.activeProviders,
                    percentages: menuBarPercentages
                ) {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .interpolation(.high)
                } else {
                    menuBarTextLabel
                }
            case .worstPercent, .monthlyCost:
                menuBarTextLabel
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var menuBarTextLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.50percent")
            if !model.menuBarText.isEmpty {
                Text(model.menuBarText)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
    }

    private var menuBarPercentages: [ProviderID: String] {
        Dictionary(uniqueKeysWithValues: model.activeProviders.map { ($0, percentText(for: $0)) })
    }

    private func percentText(for provider: ProviderID) -> String {
        guard let value = model.snapshots[provider]?.worstPercent else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    private var accessibilityText: String {
        switch model.settings.menuBarMode {
        case .iconOnly:
            return "Usage Tracker"
        case .compact:
            guard !model.activeProviders.isEmpty else {
                return "Usage Tracker: sin proveedores activos"
            }
            let parts = model.activeProviders.map { provider in
                let value = model.snapshots[provider]?.worstPercent
                let percent = value.map { "\(Int($0.rounded())) por ciento" } ?? "sin datos"
                return "\(provider.displayName) \(percent)"
            }
            return "Usage Tracker: " + parts.joined(separator: ", ")
        case .worstPercent, .monthlyCost:
            return "Usage Tracker: \(model.menuBarText.isEmpty ? "estado" : model.menuBarText)"
        }
    }
}

struct PopoverView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var tab: PopoverTab = .usage

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            model.refreshIfNeeded()
        }
    }

    private var isLoading: Bool {
        tab == .models ? model.isCatalogLoading : model.isRefreshing
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(PopoverTab.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task {
                    if tab == .models {
                        await model.refreshCatalog()
                    } else {
                        await model.refresh()
                    }
                }
            }
            label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(isLoading)
            .help(tab == .models ? "Actualizar catálogo de modelos" : "Actualizar uso")

            Button {
                openDashboard(.settings)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Abrir ajustes completos")
            .accessibilityLabel("Abrir ajustes completos")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if tab == .models {
                ModelsCatalogView(model: model, compact: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                usageContent
            }
        }
        .frame(height: 580)
    }

    private var usageContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                usageSummary

                if let update = model.availableUpdate {
                    UpdateBanner(
                        update: update,
                        isDownloading: model.isDownloadingUpdate,
                        onDownload: {
                            Task { await model.downloadUpdate(update) }
                        },
                        onDismiss: model.dismissUpdate
                    )
                }

                if let error = model.lastError {
                    ErrorBanner(message: error, onDismiss: model.clearError)
                }

                if let latest = model.visibleAlerts.last {
                    AlertRow(alert: latest, clock: model.clock) {
                        model.dismissAlert(latest)
                    }
                }

                if model.activeProviders.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "switch.2")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        Text("No hay proveedores activos")
                            .font(.subheadline.weight(.semibold))
                        Text("Actívalos desde Ajustes para ver su uso.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .card(padding: 16)
                } else {
                    ForEach(model.activeProviders) { provider in
                        if let snapshot = model.snapshots[provider] {
                            ProviderCard(
                                snapshot: snapshot,
                                subscription: model.subscription(for: provider),
                                settings: model.settings,
                                isStale: model.isStale(snapshot),
                                clock: model.clock,
                                compact: true,
                                showModels: false
                            )
                        } else {
                            LoadingCard(provider: provider)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var usageSummary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if model.settings.showEstimates {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Valor de uso")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(Format.money(model.totalUsageValue, settings: model.settings))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                    Text("estimado, no facturado")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("Valor de uso desactivado en Ajustes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("\(model.activeSubscriptions.count) activas")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .card(padding: 12)
    }

    private var footerText: String {
        tab == .models ? model.catalogUpdatedText : model.lastRefreshText
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            Button {
                openDashboard(.overview)
            } label: {
                Image(systemName: "macwindow")
                    .accessibilityLabel("Abrir dashboard")
            }
            .buttonStyle(.borderless)
            .help("Abrir dashboard completo")

            Text("v\(model.appVersion)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .accessibilityLabel("Salir")
            }
            .buttonStyle(.borderless)
            .help("Salir de Usage Tracker")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func openDashboard(_ destination: DashboardTab) {
        dismiss()
        model.dashboardTab = destination
        NSApp.activate(ignoringOtherApps: true)
        let openWindow = openWindow
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            openWindow(id: "dashboard")
        }
    }
}
