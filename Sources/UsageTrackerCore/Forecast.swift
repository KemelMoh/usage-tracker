import Foundation

public enum ForecastConfidence: String, Codable, Sendable {
    case low
    case medium
    case high

    public var label: String {
        switch self {
        case .low: return "poca confianza"
        case .medium: return "confianza media"
        case .high: return "alta confianza"
        }
    }
}

public struct Forecast: Codable, Hashable, Sendable {
    public var projectedPercent: Double
    public var burnPerHour: Double
    public var confidence: ForecastConfidence
    public var willExceed: Bool

    public init(
        projectedPercent: Double,
        burnPerHour: Double,
        confidence: ForecastConfidence,
        willExceed: Bool
    ) {
        self.projectedPercent = projectedPercent
        self.burnPerHour = burnPerHour
        self.confidence = confidence
        self.willExceed = willExceed
    }
}

public enum ForecastCalculator {
    public static func forecast(window: QuotaWindow, now: Date = Date()) -> Forecast? {
        guard !window.isUnlimited,
              let resetsAt = window.resetsAt,
              let duration = window.windowDuration,
              duration > 0 else {
            return nil
        }

        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }

        let elapsed = max(0, duration - remaining)
        let fraction = elapsed / duration
        guard fraction > 0 else { return nil }

        let projected = window.usedPercent / fraction
        let burnPerHour = window.usedPercent / max(elapsed / 3_600, 0.1)
        let confidence: ForecastConfidence
        if fraction < 0.10 {
            confidence = .low
        } else if fraction < 0.30 {
            confidence = .medium
        } else {
            confidence = .high
        }

        return Forecast(
            projectedPercent: projected,
            burnPerHour: burnPerHour,
            confidence: confidence,
            willExceed: projected >= 100
        )
    }
}
