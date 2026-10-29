import Foundation

public enum DateUtils {
    public static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }

    public static func parseDay(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    public static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    public static func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        Calendar.current.isDate(lhs, inSameDayAs: rhs)
    }

    public static func daysAgo(_ days: Int, from date: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: date) ?? date
    }

    public static func monthsAgo(_ months: Int, from date: Date = Date()) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: date) ?? date
    }

    public static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "sin fecha" }
        let seconds = max(0, date.timeIntervalSince(now))
        let days = Int(seconds / 86_400)
        let hours = Int(seconds.truncatingRemainder(dividingBy: 86_400) / 3_600)
        let minutes = Int(seconds.truncatingRemainder(dividingBy: 3_600) / 60)

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "hace unos segundos" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "hace \(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "hace \(hours) h" }
        let days = hours / 24
        return "hace \(days) d"
    }

    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    public static func shortDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func isoKey(_ date: Date) -> String {
        String(Int(date.timeIntervalSince1970))
    }
}

public enum NumberFormat {
    public static func compact(_ value: Int) -> String {
        let absolute = abs(value)
        if absolute >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if absolute >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if absolute >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    public static func decimal(_ value: Double, fractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func money(_ value: Double, currency: Currency, eurRate: Double) -> String {
        let converted = currency == .usd ? value : value * eurRate
        let fractionDigits = abs(converted) < 10 ? 2 : 0
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: currency == .usd ? "en_US" : "es_ES")
        formatter.numberStyle = .currency
        formatter.currencyCode = currency == .usd ? "USD" : "EUR"
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: converted)) ?? "\(currency.symbol)\(converted)"
    }
}
