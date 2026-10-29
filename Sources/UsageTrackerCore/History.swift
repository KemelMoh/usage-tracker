import Foundation

// MARK: - Merge

public enum HistoryMerger {
    public static func merge(
        existing: [DailyUsage],
        incoming: [DailyUsage],
        keepDays: Int = 180
    ) -> [DailyUsage] {
        var byDay: [String: DailyUsage] = [:]
        for item in existing {
            byDay[DateUtils.dayKey(item.date)] = item
        }
        for item in incoming {
            byDay[DateUtils.dayKey(item.date)] = item
        }

        let cutoff = DateUtils.daysAgo(keepDays)
        return byDay.values
            .filter { $0.date >= cutoff }
            .sorted { $0.date < $1.date }
    }
}

// MARK: - Claude

public enum ClaudeHistoryLoader {
    public static func load(days: Int = 120, prices: [ModelPrice]? = nil) -> [DailyUsage] {
        let cutoff = DateUtils.daysAgo(days)
        var byDay: [String: DailyUsage] = [:]

        let cache = loadStatsCache(prices: prices)
        for (day, models) in cache.daily {
            guard let date = DateUtils.parseDay(day), date >= cutoff else { continue }

            var totalTokens = 0
            var totalCost = 0.0
            var modelUsages: [ModelUsage] = []

            for (model, tokens) in models {
                let rate = cache.blended[model]
                    ?? PricingCatalog.price(for: model, catalog: prices).input / 1_000_000
                let cost = Double(tokens) * rate
                totalTokens += tokens
                totalCost += cost
                modelUsages.append(ModelUsage(
                    model: model,
                    tokens: TokenBreakdown(unknown: tokens),
                    costUSD: cost
                ))
            }

            modelUsages.sort { ($0.costUSD ?? 0) > ($1.costUSD ?? 0) }
            byDay[day] = DailyUsage(
                date: date,
                provider: .claude,
                tokens: TokenBreakdown(unknown: totalTokens),
                costUSD: totalCost,
                models: modelUsages
            )
        }

        let transcripts = ClaudeTranscriptScanner.scan(days: days, prices: prices)
        for (day, usage) in transcripts {
            byDay[day] = usage
        }

        return byDay.values.sorted { $0.date < $1.date }
    }

    private struct StatsCache {
        var daily: [String: [String: Int]]
        var blended: [String: Double]
    }

    private static func loadStatsCache(prices: [ModelPrice]?) -> StatsCache {
        guard let data = try? Data(contentsOf: ClaudePaths.statsCacheFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return StatsCache(daily: [:], blended: [:])
        }

        var daily: [String: [String: Int]] = [:]
        if let dailyModelTokens = root["dailyModelTokens"] as? [[String: Any]] {
            for entry in dailyModelTokens {
                guard let day = entry["date"] as? String,
                      let tokensByModel = entry["tokensByModel"] as? [String: Any] else { continue }
                var models: [String: Int] = [:]
                for (model, value) in tokensByModel {
                    models[model] = intValue(value)
                }
                daily[day] = models
            }
        }

        var blended: [String: Double] = [:]
        if let modelUsage = root["modelUsage"] as? [String: Any] {
            for (model, raw) in modelUsage {
                guard let usage = raw as? [String: Any] else { continue }
                let tokens = TokenBreakdown(
                    input: intValue(usage["inputTokens"]),
                    output: intValue(usage["outputTokens"]),
                    cacheRead: intValue(usage["cacheReadInputTokens"]),
                    cacheWrite: intValue(usage["cacheCreationInputTokens"])
                )
                guard tokens.total > 0 else { continue }
                let cost = PricingCatalog.cost(model: model, tokens: tokens, catalog: prices)
                blended[model] = cost / Double(tokens.total)
            }
        }

        return StatsCache(daily: daily, blended: blended)
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}

public enum ClaudeTranscriptScanner {
    public static func scan(days: Int = 120, prices: [ModelPrice]? = nil) -> [String: DailyUsage] {
        let fileManager = FileManager.default
        let cutoff = DateUtils.daysAgo(days)
        guard let enumerator = fileManager.enumerator(
            at: ClaudePaths.projectsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var accumulator: [String: [String: (tokens: TokenBreakdown, cost: Double)]] = [:]
        var dayDates: [String: Date] = [:]

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified >= cutoff else {
                continue
            }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }

            for line in content.split(separator: "\n") {
                guard line.contains("\"usage\""), line.contains("\"timestamp\"") else { continue }
                guard let data = line.data(using: .utf8),
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let timestamp = root["timestamp"] as? String,
                      let date = DateUtils.parseISO(timestamp),
                      date >= cutoff else {
                    continue
                }

                let message = root["message"] as? [String: Any]
                let usage = message?["usage"] as? [String: Any]
                    ?? root["usage"] as? [String: Any]
                guard let usage else { continue }

                let model = (message?["model"] as? String)
                    ?? (root["model"] as? String)
                    ?? "unknown"

                let tokens = TokenBreakdown(
                    input: intValue(usage["input_tokens"]),
                    output: intValue(usage["output_tokens"]),
                    cacheRead: intValue(usage["cache_read_input_tokens"]),
                    cacheWrite: intValue(usage["cache_creation_input_tokens"])
                )
                guard tokens.total > 0 else { continue }

                let cost = PricingCatalog.cost(model: model, tokens: tokens, catalog: prices)
                let key = DateUtils.dayKey(date)
                dayDates[key] = DateUtils.startOfDay(date)

                var models = accumulator[key] ?? [:]
                var current = models[model] ?? (.zero, 0)
                current.tokens += tokens
                current.cost += cost
                models[model] = current
                accumulator[key] = models
            }
        }

        var result: [String: DailyUsage] = [:]
        for (day, models) in accumulator {
            var totalTokens = TokenBreakdown.zero
            var totalCost = 0.0
            var usages: [ModelUsage] = []

            for (model, value) in models {
                totalTokens += value.tokens
                totalCost += value.cost
                usages.append(ModelUsage(model: model, tokens: value.tokens, costUSD: value.cost))
            }

            usages.sort { ($0.costUSD ?? 0) > ($1.costUSD ?? 0) }
            result[day] = DailyUsage(
                date: dayDates[day] ?? DateUtils.parseDay(day) ?? Date(),
                provider: .claude,
                tokens: totalTokens,
                costUSD: totalCost,
                models: usages
            )
        }

        return result
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }
}

// MARK: - OpenCode

public enum OpenCodeHistoryLoader {
    public static func load(days: Int = 120) -> [DailyUsage] {
        let database = OpenCodePaths.databaseFile
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }

        let sql = """
        SELECT date(time_created/1000,'unixepoch','localtime') AS day,
               COALESCE(json_extract(model,'$.id'),'unknown') AS model_id,
               COALESCE(SUM(cost),0) AS cost,
               COALESCE(SUM(tokens_input),0) AS input,
               COALESCE(SUM(tokens_output),0) AS output,
               COALESCE(SUM(tokens_cache_read),0) AS cache_read,
               COALESCE(SUM(tokens_cache_write),0) AS cache_write
        FROM session
        WHERE time_created >= (strftime('%s','now','-\(days) days')*1000)
          AND model LIKE '%opencode-go%'
        GROUP BY day, model_id
        ORDER BY day ASC;
        """

        guard let sqlite = ProcessRunner.findExecutable("sqlite3"),
              let output = try? ProcessRunner.run(sqlite, ["-json", database.path, sql]),
              let data = output.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var byDay: [String: DailyUsage] = [:]
        for row in rows {
            guard let day = row["day"] as? String,
                  let date = DateUtils.parseDay(day) else { continue }

            let model = row["model_id"] as? String ?? "unknown"
            let tokens = TokenBreakdown(
                input: intValue(row["input"]),
                output: intValue(row["output"]),
                cacheRead: intValue(row["cache_read"]),
                cacheWrite: intValue(row["cache_write"])
            )
            let cost = doubleValue(row["cost"])

            var usage = byDay[day] ?? DailyUsage(
                date: date,
                provider: .opencodeGo,
                tokens: .zero,
                costUSD: 0,
                models: []
            )
            usage.tokens += tokens
            usage.costUSD = (usage.costUSD ?? 0) + cost
            usage.models.append(ModelUsage(model: model, tokens: tokens, costUSD: cost))
            byDay[day] = usage
        }

        for key in byDay.keys {
            byDay[key]?.models.sort { ($0.costUSD ?? 0) > ($1.costUSD ?? 0) }
        }

        return byDay.values.sorted { $0.date < $1.date }
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let double = value as? Double { return Int(double) }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func doubleValue(_ value: Any?) -> Double {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) ?? 0 }
        return 0
    }
}
