import Foundation

public enum DateUtils {
    /// Días transcurridos desde 1970 para una fecha gregoriana (algoritmo de
    /// Howard Hinnant). Se usa para leer fechas `yyyy-MM-dd` sin pasar por
    /// `DateFormatter`, que cuesta del orden de 15 µs por llamada y se invoca
    /// una vez por modelo del catálogo.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = year - (month <= 2 ? 1 : 0)
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    /// Convierte una fecha `yyyy-MM-dd` en `Date` sin usar `DateFormatter`.
    /// Devuelve `nil` si el formato no es válido.
    public static func fastParseDay(_ value: String?) -> Date? {
        guard let value else { return nil }
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == UInt8(ascii: "-"),
              bytes[7] == UInt8(ascii: "-") else {
            return nil
        }

        func number(_ start: Int, _ end: Int) -> Int? {
            var result = 0
            for index in start..<end {
                let byte = bytes[index]
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                result = result * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return result
        }

        guard let year = number(0, 4),
              let month = number(5, 7),
              let day = number(8, 10) else {
            return nil
        }
        guard month >= 1, month <= 12, day >= 1, day <= 31 else { return nil }

        let days = daysFromCivil(year: year, month: month, day: day)
        // El resultado equivale a la medianoche local de ese día, que es lo que
        // produce `DateFormatter` con `TimeZone.current`. La medianoche local
        // se obtiene restando el desfase de la zona horaria a la medianoche
        // UTC de ese mismo día.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let utcMidnight = Date(timeIntervalSince1970: TimeInterval(days) * 86_400)
        let offset = calendar.timeZone.secondsFromGMT(for: utcMidnight)
        return utcMidnight.addingTimeInterval(TimeInterval(-offset))
    }

    // Los formateadores son caros de crear y estas funciones se llaman miles
    // de veces al recorrer catálogos e historiales. Se reutilizan. `DateFormatter`
    // no es thread-safe, así que van protegidos con un cerrojo: estas funciones
    // se llaman tanto desde la interfaz como desde las tareas asíncronas de
    // los proveedores.
    private static let dateLock = NSLock()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let fractionalISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainISO: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let shortDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    public static func parseISO(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }

        dateLock.lock()
        defer { dateLock.unlock() }
        if let date = fractionalISO.date(from: value) {
            return date
        }
        return plainISO.date(from: value)
    }

    public static func parseDay(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // La vía rápida cubre el formato `yyyy-MM-dd` de models.dev, que es el
        // caso habitual. Si no encaja, se recurre al formateador.
        if let fast = fastParseDay(value) { return fast }
        dateLock.lock()
        defer { dateLock.unlock() }
        return dayFormatter.date(from: value)
    }

    public static func dayKey(_ date: Date) -> String {
        dateLock.lock()
        defer { dateLock.unlock() }
        return dayFormatter.string(from: date)
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
        dateLock.lock()
        defer { dateLock.unlock() }
        return shortDateFormatter.string(from: date)
    }

    public static func shortDateTime(_ date: Date) -> String {
        dateLock.lock()
        defer { dateLock.unlock() }
        return shortDateTimeFormatter.string(from: date)
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

    // Los formateadores se reutilizan: se crean en cada fila de las listas de
    // precios y de historial, donde el coste de crearlos se nota. Se ajustan
    // antes de cada uso, así que van protegidos con un cerrojo: estas
    // funciones se llaman tanto desde la interfaz como desde las tareas
    // asíncronas de los proveedores.
    private static let formatterLock = NSLock()

    private static let decimalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let usdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        return formatter
    }()

    private static let eurFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "es_ES")
        formatter.numberStyle = .currency
        formatter.currencyCode = "EUR"
        return formatter
    }()

    public static func decimal(_ value: Double, fractionDigits: Int = 0) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        decimalFormatter.minimumFractionDigits = fractionDigits
        decimalFormatter.maximumFractionDigits = fractionDigits
        return decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func money(_ value: Double, currency: Currency, eurRate: Double) -> String {
        let converted = currency == .usd ? value : value * eurRate
        let fractionDigits = abs(converted) < 10 ? 2 : 0
        formatterLock.lock()
        defer { formatterLock.unlock() }
        let formatter = currency == .usd ? usdFormatter : eurFormatter
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: converted)) ?? "\(currency.symbol)\(converted)"
    }
}
