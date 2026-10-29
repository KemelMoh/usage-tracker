import Foundation

// MARK: - HTTP

public final class HTTPClient {
    public static let shared = HTTPClient()

    static let allowedHosts: Set<String> = [
        "opencode.ai",
        "api.github.com",
        "api.anthropic.com",
        "models.dev"
    ]

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(
            configuration: configuration,
            delegate: RedirectGuard(),
            delegateQueue: nil
        )
    }

    public func get(url: URL, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        guard let host = url.host, Self.allowedHosts.contains(host) else {
            throw ProviderError.network("Host no permitido: \(url.host ?? "desconocido").")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("Respuesta no HTTP.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let snippet = Self.sanitize(String(data: data, encoding: .utf8) ?? "")
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ProviderError.auth("Credenciales rechazadas (HTTP \(http.statusCode)). Reautentica el proveedor.")
            }
            throw ProviderError.http(http.statusCode, snippet)
        }

        return (data, http)
    }

    private static func sanitize(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = [
            "sk-[A-Za-z0-9_-]{8,}",
            "gho_[A-Za-z0-9_]{8,}",
            "github_pat_[A-Za-z0-9_]{8,}",
            "Bearer [A-Za-z0-9._-]{8,}"
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        return String(result.prefix(200))
    }
}

private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let host = request.url?.host,
              HTTPClient.allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

// MARK: - OpenCode Go

public struct OpenCodeGoClient: Sendable {
    public init() {}

    public func fetch(apiKey: String?, planName: String) async -> ProviderSnapshot {
        guard let apiKey, !apiKey.isEmpty else {
            return .failure(
                provider: .opencodeGo,
                planName: planName,
                error: ProviderError.missingCredential(
                    "No se encontró la API key de OpenCode Go. Conecta OpenCode Go en OpenCode o pega una key en Ajustes."
                )
            )
        }

        do {
            guard let url = URL(string: "https://opencode.ai/zen/go/v1/usage") else {
                throw ProviderError.network("URL no válida.")
            }
            let (data, _) = try await HTTPClient.shared.get(url: url, headers: [
                "Authorization": "Bearer \(apiKey)",
                "Accept": "application/json",
                "User-Agent": "UsageTracker/0.1"
            ])

            let response = try JSONDecoder().decode(OpenCodeUsageResponse.self, from: data)
            let windows = [
                quota(id: "rolling5h", label: "5 horas", window: response.usage.rolling, duration: 5 * 3_600),
                quota(id: "weekly", label: "Semanal", window: response.usage.weekly, duration: 7 * 86_400),
                quota(id: "monthly", label: "Mensual", window: response.usage.monthly, duration: 30 * 86_400)
            ]

            return ProviderSnapshot(
                provider: .opencodeGo,
                planName: planName,
                status: .ok,
                windows: windows
            )
        } catch let error as ProviderError {
            if case .auth = error {
                return .failure(
                    provider: .opencodeGo,
                    planName: planName,
                    error: ProviderError.auth("La API key de OpenCode Go no es válida o ha caducado.")
                )
            }
            return .failure(provider: .opencodeGo, planName: planName, error: error)
        } catch {
            return .failure(provider: .opencodeGo, planName: planName, error: error)
        }
    }

    private func quota(
        id: String,
        label: String,
        window: OpenCodeUsageResponse.Window,
        duration: TimeInterval
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            label: label,
            usedPercent: window.percent ?? 0,
            resetsAt: DateUtils.parseISO(window.resetsAt),
            windowDuration: duration
        )
    }
}

private struct OpenCodeUsageResponse: Decodable {
    let usage: Usage

    struct Usage: Decodable {
        let rolling: Window
        let weekly: Window
        let monthly: Window
    }

    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?
    }
}

/// El listado en vivo de OpenCode Go no requiere autenticación y sirve para
/// conocer qué modelos están disponibles además de los precios de models.dev.
public struct OpenCodeModelsClient: Sendable {
    public init() {}

    public func fetchIDs() async throws -> [String] {
        guard let url = URL(string: "https://opencode.ai/zen/go/v1/models") else {
            throw ProviderError.network("URL no válida.")
        }
        let (data, _) = try await HTTPClient.shared.get(url: url, headers: [
            "Accept": "application/json",
            "User-Agent": "UsageTracker/0.2"
        ])
        let response = try JSONDecoder().decode(OpenCodeModelsResponse.self, from: data)
        return response.data.map(\.id)
    }
}

private struct OpenCodeModelsResponse: Decodable {
    let data: [Model]

    struct Model: Decodable {
        let id: String
    }
}

// MARK: - GitHub Copilot

public struct CopilotClient: Sendable {
    public init() {}

    public func fetch(token: String?, fallbackPlan: String = "Business") async -> ProviderSnapshot {
        guard let token, !token.isEmpty else {
            return .failure(
                provider: .copilot,
                planName: fallbackPlan,
                error: ProviderError.missingCredential(
                    "No se encontró un token de GitHub. Ejecuta `gh auth login` o pega un token en Ajustes."
                )
            )
        }

        do {
            guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
                throw ProviderError.network("URL no válida.")
            }
            let (data, _) = try await HTTPClient.shared.get(url: url, headers: [
                "Authorization": "Bearer \(token)",
                "Accept": "application/json",
                "User-Agent": "UsageTracker/0.1"
            ])

            let response = try JSONDecoder().decode(CopilotUserResponse.self, from: data)
            let planName = CopilotPlanCatalog.normalizedName(response.copilot_plan)
            let resetDate = DateUtils.parseDay(response.quota_reset_date)

            guard let quota = response.quota_snapshots?["premium_interactions"] else {
                throw ProviderError.decoding("No se encontró el cupo de premium requests.")
            }

            let window: QuotaWindow
            if quota.unlimited == true {
                window = QuotaWindow(
                    id: "premium",
                    label: "Premium requests",
                    usedPercent: 0,
                    resetsAt: resetDate,
                    windowDuration: 30 * 86_400,
                    detail: "Ilimitado",
                    isUnlimited: true,
                    usedValue: 0,
                    limitValue: 0
                )
            } else {
                let entitlement = quota.entitlement ?? 0
                let remaining = quota.remaining ?? 0
                let used = max(0, entitlement - remaining)
                let percentUsed: Double
                if let percentRemaining = quota.percent_remaining {
                    percentUsed = max(0, 100 - percentRemaining)
                } else if entitlement > 0 {
                    percentUsed = used / entitlement * 100
                } else {
                    percentUsed = 0
                }

                window = QuotaWindow(
                    id: "premium",
                    label: "Premium requests",
                    usedPercent: percentUsed,
                    resetsAt: resetDate,
                    windowDuration: 30 * 86_400,
                    detail: "\(NumberFormat.decimal(used))/\(NumberFormat.decimal(entitlement))",
                    usedValue: used,
                    limitValue: entitlement
                )
            }

            return ProviderSnapshot(
                provider: .copilot,
                planName: planName,
                status: .ok,
                windows: [window],
                accountLabel: response.login
            )
        } catch let error as ProviderError {
            if case .auth = error {
                return .failure(
                    provider: .copilot,
                    planName: fallbackPlan,
                    error: ProviderError.auth("El token de GitHub no tiene acceso a Copilot o ha caducado. Ejecuta `gh auth login`.")
                )
            }
            return .failure(provider: .copilot, planName: fallbackPlan, error: error)
        } catch {
            return .failure(provider: .copilot, planName: fallbackPlan, error: error)
        }
    }
}

private struct CopilotUserResponse: Decodable {
    let copilot_plan: String?
    let quota_reset_date: String?
    let login: String?
    let quota_snapshots: [String: Quota]?

    struct Quota: Decodable {
        let entitlement: Double?
        let remaining: Double?
        let percent_remaining: Double?
        let unlimited: Bool?
        let quota_id: String?
        let credits_used: Double?
    }
}

// MARK: - Claude

public struct ClaudeClient: Sendable {
    public init() {}

    public func fetch(credentials: ClaudeCredentials?, fallbackPlan: String) async -> ProviderSnapshot {
        guard let credentials else {
            return .failure(
                provider: .claude,
                planName: fallbackPlan,
                error: ProviderError.missingCredential(
                    "No se encontró la sesión de Claude Code. Inicia sesión con `claude` o pega un token en Ajustes."
                )
            )
        }

        if credentials.isExpired {
            return .failure(
                provider: .claude,
                planName: credentials.inferredPlan ?? fallbackPlan,
                error: ProviderError.auth(
                    "La sesión de Claude caducó. Abre Claude Code para renovarla."
                )
            )
        }

        do {
            guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
                throw ProviderError.network("URL no válida.")
            }
            let (data, _) = try await HTTPClient.shared.get(url: url, headers: [
                "Authorization": "Bearer \(credentials.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "anthropic-version": "2023-06-01",
                "Accept": "application/json",
                "User-Agent": "UsageTracker/0.1"
            ])

            let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            var windows: [QuotaWindow] = []

            if let fiveHour = response.five_hour {
                windows.append(fiveHour.quota(id: "five_hour", label: "5 horas", duration: 5 * 3_600))
            }
            if let sevenDay = response.seven_day {
                windows.append(sevenDay.quota(id: "seven_day", label: "7 días", duration: 7 * 86_400))
            }
            if let opus = response.seven_day_opus {
                windows.append(opus.quota(id: "seven_day_opus", label: "7 días · Opus", duration: 7 * 86_400))
            }
            if let sonnet = response.seven_day_sonnet {
                windows.append(sonnet.quota(id: "seven_day_sonnet", label: "7 días · Sonnet", duration: 7 * 86_400))
            }

            if let extra = response.extra_usage, extra.is_enabled == true, let utilization = extra.utilization {
                let detail: String?
                if let used = extra.used_credits, let limit = extra.monthly_limit {
                    detail = "\(NumberFormat.money(used, currency: .usd, eurRate: 1)) de \(NumberFormat.money(limit, currency: .usd, eurRate: 1))"
                } else {
                    detail = nil
                }
                windows.append(QuotaWindow(
                    id: "extra_usage",
                    label: "Créditos extra",
                    usedPercent: utilization,
                    windowDuration: 30 * 86_400,
                    detail: detail
                ))
            }

            guard !windows.isEmpty else {
                throw ProviderError.decoding("La respuesta no contiene ventanas de uso.")
            }

            return ProviderSnapshot(
                provider: .claude,
                planName: credentials.inferredPlan ?? fallbackPlan,
                status: .ok,
                windows: windows,
                accountLabel: credentials.subscriptionType
            )
        } catch let error as ProviderError {
            if case .auth = error {
                return .failure(
                    provider: .claude,
                    planName: credentials.inferredPlan ?? fallbackPlan,
                    error: ProviderError.auth(
                        "La sesión de Claude caducó o no es válida. Abre Claude Code para renovarla."
                    )
                )
            }
            return .failure(
                provider: .claude,
                planName: credentials.inferredPlan ?? fallbackPlan,
                error: error
            )
        } catch {
            return .failure(
                provider: .claude,
                planName: credentials.inferredPlan ?? fallbackPlan,
                error: error
            )
        }
    }
}

private struct ClaudeUsageResponse: Decodable {
    let five_hour: Window?
    let seven_day: Window?
    let seven_day_opus: Window?
    let seven_day_sonnet: Window?
    let extra_usage: Extra?

    struct Window: Decodable {
        let utilization: Double?
        let resets_at: String?

        func quota(id: String, label: String, duration: TimeInterval) -> QuotaWindow {
            QuotaWindow(
                id: id,
                label: label,
                usedPercent: utilization ?? 0,
                resetsAt: DateUtils.parseISO(resets_at),
                windowDuration: duration
            )
        }
    }

    struct Extra: Decodable {
        let is_enabled: Bool?
        let monthly_limit: Double?
        let used_credits: Double?
        let utilization: Double?
    }
}
