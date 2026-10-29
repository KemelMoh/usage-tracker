import SwiftUI
import AppKit
import UsageTrackerCore

struct StatusBadge: View {
    let status: ProviderStatus
    var stale: Bool = false

    private var effective: ProviderStatus {
        stale && status == .ok ? .stale : status
    }

    var body: some View {
        if effective != .ok {
            Text(effective.label)
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .foregroundStyle(Theme.statusColor(for: effective))
                .background(Theme.statusColor(for: effective).opacity(0.12), in: Capsule())
        }
    }
}

struct ProviderIcon: View {
    let provider: ProviderID
    var size: CGFloat = 34

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool {
        if colorScheme == .dark { return true }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    var body: some View {
        Group {
            if let image = ProviderIconAsset.image(for: provider, isDark: isDark) {
                let icon = Image(nsImage: image)
                    .renderingMode(.original)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)

                if provider == .opencodeGo {
                    icon.shadow(color: .black.opacity(0.18), radius: 0.8, y: 0.5)
                } else {
                    icon
                }
            } else {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(provider.color.gradient)
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: provider.symbolName)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    )
            }
        }
        .accessibilityLabel(provider.displayName)
    }
}

private enum ProviderIconAsset {
    static func image(for provider: ProviderID, isDark: Bool) -> NSImage? {
        let name: String
        switch provider {
        case .opencodeGo:
            name = "opencode"
        case .copilot:
            name = isDark ? "copilot-dark" : "copilot"
        case .claude:
            name = "claude"
        }

        return load(named: name)
    }

    static func menuBarImage(for provider: ProviderID, size: CGFloat) -> NSImage? {
        let name: String
        switch provider {
        case .opencodeGo:
            name = "opencode-menu"
        case .copilot:
            name = "copilot-menu"
        case .claude:
            name = "claude-menu"
        }

        guard let image = load(named: name) else { return nil }
        // El tamaño lógico debe ser el del menú, no los 256 px del PNG.
        image.size = NSSize(width: size, height: size)
        return image
    }

    private static func load(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "ProviderIcons"
        ) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

enum MenuBarProviderImage {
    static func make(providers: [ProviderID], percentages: [ProviderID: String]) -> NSImage? {
        guard !providers.isEmpty else { return nil }

        let iconSize: CGFloat = 16
        let iconTextGap: CGFloat = 2
        let groupGap: CGFloat = 8
        let height: CGFloat = 18
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let values = providers.map { percentages[$0] ?? "—" }
        let textWidths = values.map { ($0 as NSString).size(withAttributes: attributes).width }

        var width: CGFloat = 2
        for (index, textWidth) in textWidths.enumerated() {
            if index > 0 { width += groupGap }
            width += iconSize + iconTextGap + textWidth
        }

        let image = NSImage(size: NSSize(width: ceil(width), height: height), flipped: false) { _ in
            NSColor.clear.setFill()
            NSRect(origin: .zero, size: NSSize(width: ceil(width), height: height)).fill()
            NSGraphicsContext.current?.imageInterpolation = .high
            var x: CGFloat = 1

            for (index, provider) in providers.enumerated() {
                if index > 0 { x += groupGap }

                if let icon = ProviderIconAsset.menuBarImage(for: provider, size: iconSize) {
                    icon.draw(
                        in: NSRect(
                            x: x,
                            y: (height - iconSize) / 2,
                            width: iconSize,
                            height: iconSize
                        ),
                        from: NSRect(origin: .zero, size: icon.size),
                        operation: .sourceOver,
                        fraction: 1
                    )
                }
                x += iconSize + iconTextGap

                let value = values[index] as NSString
                let textSize = value.size(withAttributes: attributes)
                value.draw(
                    at: NSPoint(x: x, y: (height - textSize.height) / 2),
                    withAttributes: attributes
                )
                x += textSize.width
            }

            return true
        }
        image.isTemplate = true
        return image
    }
}

struct ProgressBar: View {
    let value: Double
    let color: Color
    var height: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(max(0, min(1, value / 100)))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(color.gradient)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: height)
        .accessibilityValue("\(Int(value.rounded()))%")
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    let provider: ProviderID
    let now: Date
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label)
                    .font(.caption.weight(.medium))
                Spacer()
                if window.isUnlimited {
                    Text("Ilimitado")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(Format.percent(window.usedPercent))
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.statusColor(for: window.usedPercent))
                }
            }

            if !window.isUnlimited {
                ProgressBar(
                    value: window.usedPercent,
                    color: Theme.statusColor(for: window.usedPercent),
                    height: compact ? 5 : 7
                )
            }

            HStack(spacing: 6) {
                if let detail = window.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let resetsAt = window.resetsAt {
                    if window.detail != nil {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text("Reinicio en \(Format.countdown(resetsAt, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("Tiempo hasta que se reinicie esta ventana de cuota")
                }
                Spacer()
                if !window.isUnlimited,
                   let forecast = ForecastCalculator.forecast(window: window, now: now) {
                    Text("Previsión \(Format.percent(forecast.projectedPercent))")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(forecast.willExceed ? .red : .secondary)
                        .lineLimit(1)
                        .help("Previsión al final de la ventana (\(forecast.confidence.label))")
                }
            }
        }
    }
}

struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let subscription: Subscription
    let settings: AppSettings
    let isStale: Bool
    let now: Date
    var compact: Bool = false
    var showModels: Bool = true

    private var planLine: String {
        if let option = snapshot.provider.planOption(named: snapshot.planName) {
            switch option.kind {
            case .included:
                return "\(snapshot.planName) · incluido"
            case .perSeat:
                return "\(snapshot.planName) · por asiento"
            case .personal:
                break
            }
        }
        return snapshot.planName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: snapshot.provider, size: compact ? 30 : 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.provider.displayName)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                    HStack(spacing: 4) {
                        Text(planLine)
                        if subscription.priceSource == .auto,
                           snapshot.provider.supportsPlanDetection {
                            Text("auto")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.tertiary)
                                .help("Plan detectado automáticamente")
                        }
                        if !subscription.isActive {
                            Text("· inactiva")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadge(status: snapshot.status, stale: isStale)
            }

            if let error = snapshot.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: snapshot.status == .needsAuth ? "key.slash" : "exclamationmark.triangle.fill")
                        .foregroundStyle(snapshot.status == .needsAuth ? .orange : .red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            } else if snapshot.windows.isEmpty {
                Text("Sin datos de cuota todavía.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: compact ? 8 : 12) {
                    ForEach(snapshot.windows) { window in
                        QuotaRow(window: window, provider: snapshot.provider, now: now, compact: compact)
                    }
                }
            }

            if showModels, !snapshot.models.isEmpty {
                Divider()
                Text("Modelos más usados · 30 días")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(snapshot.models.prefix(3)) { model in
                    HStack(spacing: 8) {
                        Text(model.model)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Text(Format.tokens(model.tokens.total))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        if let cost = model.costUSD, cost > 0 {
                            Text(Format.money(cost, settings: settings))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .card(padding: compact ? 14 : 18)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    let symbol: String
    var color: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.14))
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(color)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UpdateBanner: View {
    let update: AppUpdate
    let isDownloading: Bool
    let onDownload: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Actualización \(update.version) disponible")
                    .font(.caption.weight(.semibold))
                Text("Descarga el DMG y arrástralo a Aplicaciones.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button {
                onDownload()
            } label: {
                if isDownloading {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Text("Descargar")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isDownloading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Ignorar esta actualización")
        }
        .padding(10)
        .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AlertRow: View {
    let alert: AppAlert
    let now: Date
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Theme.severityColor(alert.severity))
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.title)
                    .font(.caption.weight(.semibold))
                Text(alert.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(Format.relative(alert.date, now: now))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Eliminar alerta")
                .accessibilityLabel("Eliminar alerta")
            }
        }
        .padding(10)
        .background(
            Theme.severityColor(alert.severity).opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
    }
}

struct LoadingCard: View {
    let provider: ProviderID

    var body: some View {
        HStack(spacing: 12) {
            ProviderIcon(provider: provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(.headline)
                Text("Cargando cuota…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView()
                .controlSize(.small)
        }
        .card(padding: 14)
    }
}

struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
