import Foundation

public struct AlertEvaluation: Sendable {
    public var newAlerts: [AppAlert]
    public var keys: [String: Date]

    public init(newAlerts: [AppAlert], keys: [String: Date]) {
        self.newAlerts = newAlerts
        self.keys = keys
    }
}

public enum AlertEngine {
    public static func evaluate(
        snapshots: [ProviderID: ProviderSnapshot],
        settings: AppSettings,
        existingKeys: [String: Date],
        now: Date = Date()
    ) -> AlertEvaluation {
        guard settings.alertsEnabled else {
            return AlertEvaluation(newAlerts: [], keys: existingKeys)
        }

        var keys = existingKeys
        var alerts: [AppAlert] = []
        let thresholds = settings.alertThresholds.sorted()

        for provider in ProviderID.allCases {
            guard settings.subscription(for: provider)?.isActive ?? true else { continue }
            guard let snapshot = snapshots[provider], snapshot.status == .ok else { continue }

            for window in snapshot.windows where !window.isUnlimited {
                let resetKey = window.resetsAt.map { DateUtils.isoKey($0) } ?? "none"
                let crossed = thresholds.last(where: { window.usedPercent >= $0 })

                if let threshold = crossed {
                    let key = "\(provider.rawValue)|\(window.id)|\(Int(threshold))|\(resetKey)"
                    if keys[key] == nil {
                        keys[key] = now
                        let severity: AlertSeverity
                        if threshold >= 100 {
                            severity = .critical
                        } else if threshold >= 90 {
                            severity = .warning
                        } else {
                            severity = .info
                        }

                        let resetText: String
                        if let resetsAt = window.resetsAt {
                            resetText = " Reinicia en \(DateUtils.countdown(to: resetsAt, now: now))."
                        } else {
                            resetText = ""
                        }

                        alerts.append(AppAlert(
                            provider: provider,
                            title: "\(provider.displayName) · \(window.label) al \(Int(threshold))%",
                            message: "Uso actual: \(Int(window.usedPercent.rounded()))%.\(resetText)",
                            date: now,
                            severity: severity
                        ))
                    }
                }

                if let forecast = ForecastCalculator.forecast(window: window, now: now),
                   forecast.willExceed,
                   forecast.confidence != .low {
                    let key = "\(provider.rawValue)|\(window.id)|forecast|\(resetKey)"
                    if keys[key] == nil {
                        keys[key] = now
                        alerts.append(AppAlert(
                            provider: provider,
                            title: "\(provider.displayName) · previsión alta",
                            message: "A este ritmo llegarás al \(Int(forecast.projectedPercent.rounded()))% antes del reinicio.",
                            date: now,
                            severity: .warning
                        ))
                    }
                }
            }
        }

        return AlertEvaluation(newAlerts: alerts, keys: keys)
    }
}
