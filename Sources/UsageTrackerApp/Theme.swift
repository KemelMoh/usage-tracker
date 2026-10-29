import SwiftUI
import UsageTrackerCore

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red, green, blue, alpha: UInt64
        switch cleaned.count {
        case 8:
            red = (value >> 24) & 0xFF
            green = (value >> 16) & 0xFF
            blue = (value >> 8) & 0xFF
            alpha = value & 0xFF
        default:
            red = (value >> 16) & 0xFF
            green = (value >> 8) & 0xFF
            blue = value & 0xFF
            alpha = 255
        }
        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

extension ProviderID {
    var color: Color {
        Color(hex: accentHex)
    }

    var softColor: Color {
        color.opacity(0.12)
    }
}

enum Theme {
    static func statusColor(for percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent >= 90 { return .red }
        if percent >= 75 { return .orange }
        return .green
    }

    static func statusColor(for status: ProviderStatus) -> Color {
        switch status {
        case .ok: return .green
        case .needsAuth: return .orange
        case .error: return .red
        case .stale: return .gray
        case .loading: return .secondary
        }
    }

    static func severityColor(_ severity: AlertSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .warning: return .orange
        case .critical: return .red
        }
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }
}

enum Format {
    static func money(_ value: Double, settings: AppSettings) -> String {
        NumberFormat.money(
            value,
            currency: settings.currency,
            eurRate: Currency.usdToEURRate
        )
    }

    static func money(_ value: Double, currency: Currency, eurRate: Double) -> String {
        NumberFormat.money(value, currency: currency, eurRate: eurRate)
    }

    static func tokens(_ value: Int) -> String {
        NumberFormat.compact(value)
    }

    static func number(_ value: Double, digits: Int = 0) -> String {
        NumberFormat.decimal(value, fractionDigits: digits)
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    /// Precio por millón de tokens con precisión suficiente para tarifas pequeñas.
    static func pricePerMillion(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 0.1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    static func countdown(_ date: Date?, now: Date) -> String {
        DateUtils.countdown(to: date, now: now)
    }

    static func relative(_ date: Date, now: Date) -> String {
        DateUtils.relative(date, now: now)
    }

    static func date(_ date: Date) -> String {
        DateUtils.shortDate(date)
    }

    static func dateTime(_ date: Date) -> String {
        DateUtils.shortDateTime(date)
    }
}
