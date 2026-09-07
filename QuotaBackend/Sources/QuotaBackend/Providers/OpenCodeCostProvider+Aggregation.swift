import Foundation

// MARK: - OpenCode Aggregation & Date Utils
// 按日聚合与时间线编码，复用通用聚合结构（CodexAggregateBucket / CodexRow）。
// 与 Codex/Claude 同口径：本地时区日界、timeline 仅按日（冻结归档无小时粒度）。

extension OpenCodeCostProvider {

    struct TimelineBucket {
        let bucket: String
        let label: String
        let estimatedCostUsd: Double
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheCreateTokens: Int = 0
        let totalTokens: Int
    }

    static let currencyFormatterLock = NSLock()
    static let standardCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
    static let fractionalCurrencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 4
        formatter.maximumFractionDigits = 4
        return formatter
    }()

    // MARK: Aggregation

    func aggregateDays(
        _ bucketsByDay: [String: CodexAggregateBucket],
        matching: (String) -> Bool
    ) -> CodexAggregateBucket {
        var result = CodexAggregateBucket.empty
        for (day, bucket) in bucketsByDay where matching(day) {
            result.merge(bucket)
        }
        return result
    }

    typealias BucketMetrics = (estimatedCostUsd: Double, totalTokens: Int,
                               inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheCreateTokens: Int)

    func bucketMetrics(
        _ bucket: CodexAggregateBucket?,
        model: String?
    ) -> BucketMetrics {
        guard let bucket else { return (0, 0, 0, 0, 0, 0) }
        if let model {
            guard let m = bucket.models[model] else { return (0, 0, 0, 0, 0, 0) }
            return (m.estimatedCostUsd, m.totalTokens,
                    m.inputTokens, m.outputTokens, m.cacheReadTokens, m.cacheCreateTokens)
        }
        var inp = 0; var out = 0; var cR = 0; var cC = 0
        for m in bucket.models.values {
            inp += m.inputTokens; out += m.outputTokens; cR += m.cacheReadTokens
            cC += m.cacheCreateTokens
        }
        return (bucket.estimatedCostUsd, bucket.totalTokens, inp, out, cR, cC)
    }

    func trailingDailyTimeline(
        bucketsByDay: [String: CodexAggregateBucket],
        now: Date,
        dayCount: Int,
        model: String? = nil
    ) -> [TimelineBucket] {
        let calendar = calendar()
        let today = calendar.startOfDay(for: now)
        let count = max(dayCount, 1)
        let start = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today

        return (0..<count).compactMap { offset -> TimelineBucket? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = dayKey(day)
            let m = bucketMetrics(bucketsByDay[key], model: model)
            return TimelineBucket(
                bucket: key,
                label: dayBucketLabel(day),
                estimatedCostUsd: roundUsd(m.estimatedCostUsd),
                inputTokens: m.inputTokens,
                outputTokens: m.outputTokens,
                cacheReadTokens: m.cacheReadTokens,
                cacheCreateTokens: m.cacheCreateTokens,
                totalTokens: m.totalTokens
            )
        }
    }

    func encodeTimeline(_ buckets: [TimelineBucket], includeDetail: Bool = false) -> [AnyCodable] {
        buckets.map { bucket in
            var dict: [String: AnyCodable] = [
                "bucket": AnyCodable(bucket.bucket),
                "label": AnyCodable(bucket.label),
                "usd": AnyCodable(bucket.estimatedCostUsd),
                "tokens": AnyCodable(bucket.totalTokens)
            ]
            if includeDetail {
                dict["inputTokens"] = AnyCodable(bucket.inputTokens)
                dict["outputTokens"] = AnyCodable(bucket.outputTokens)
                dict["cacheReadTokens"] = AnyCodable(bucket.cacheReadTokens)
                dict["cacheCreateTokens"] = AnyCodable(bucket.cacheCreateTokens)
            }
            return AnyCodable(dict)
        }
    }

    // MARK: Date Utils

    func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func dayKey(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM-dd", timeZone: timeZone)
    }

    func monthKeyStr(_ date: Date) -> String {
        DateFormat.string(from: date, format: "yyyy-MM", timeZone: timeZone)
    }

    func dayBucketLabel(_ date: Date) -> String {
        DateFormat.string(from: date, format: "MM/dd", timeZone: timeZone)
    }

    func currentWeekRange(_ date: Date) -> (start: String, end: String, dayKeys: Set<String>) {
        let cal = calendar()
        let comps = cal.dateComponents(in: timeZone, from: date)
        let weekday = comps.weekday ?? 1
        let offset = (weekday + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -offset, to: date) else {
            let key = dayKey(date)
            return (start: key, end: key, dayKeys: [key])
        }
        var keys = Set<String>()
        for i in 0..<7 {
            if let day = cal.date(byAdding: .day, value: i, to: monday) {
                keys.insert(dayKey(day))
            }
        }
        let end = cal.date(byAdding: .day, value: 6, to: monday).map(dayKey) ?? dayKey(monday)
        return (start: dayKey(monday), end: end, dayKeys: keys)
    }

    /// 扫描窗口起点（含当天在内共 defaultScanDays 天）的 epoch 毫秒，用于下推 SQL 过滤。
    func scanWindowStartMillis(now: Date) -> Int64 {
        let cal = calendar()
        let today = cal.startOfDay(for: now)
        let since = cal.date(byAdding: .day, value: -(Self.defaultScanDays - 1), to: today) ?? today
        return Int64(since.timeIntervalSince1970 * 1000)
    }

    func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else {
            return nil
        }
        var comps = DateComponents()
        comps.calendar = calendar()
        comps.timeZone = timeZone
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    func archivedDayCount(
        _ bucketsByDay: [String: CodexAggregateBucket],
        now: Date,
        fallback: Int
    ) -> Int {
        guard let firstKey = bucketsByDay.keys.sorted().first,
              let firstDay = dateFromDayKey(firstKey) else {
            return fallback
        }
        let days = calendar().dateComponents(
            [.day],
            from: calendar().startOfDay(for: firstDay),
            to: calendar().startOfDay(for: now)
        ).day.map { $0 + 1 } ?? fallback
        return max(days, fallback)
    }

    func archivedRangeLabel(
        _ bucketsByDay: [String: CodexAggregateBucket],
        fallback: String
    ) -> String {
        let keys = bucketsByDay.keys.sorted()
        guard let first = keys.first, let last = keys.last else { return fallback }
        if first == last { return first }
        return "\(first)..\(last)"
    }

    func roundUsd(_ value: Double) -> Double {
        (value * 1_000_000).rounded() / 1_000_000
    }

    func formatCurrency(_ value: Double) -> String {
        let formatter = value >= 1 ? Self.standardCurrencyFormatter : Self.fractionalCurrencyFormatter
        Self.currencyFormatterLock.lock()
        defer { Self.currencyFormatterLock.unlock() }
        return formatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }
}
