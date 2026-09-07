import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - OpenCode Cost Provider
// 读取 OpenCode（≥ v1.2）本地 SQLite 会话库，统计 token 用量与成本。单轨（无代理/非代理之分）。
// 数据来源: ~/.local/share/opencode/opencode.db（或 $XDG_DATA_HOME、桌面版 Application Support），
//          message 表每条 assistant 消息自带 token 明细与按 models.dev 定价预计算的 cost。
// 工作方式: 复制 db 临时快照 → 只读查询 → 按日聚合 → 冻结归档（昨日前冻结、今天重算）→ costSummary。
// 订阅渠道（OAuth）cost 恒 0，属「订阅不计费」而非「未定价」，本 provider 不产生未定价告警。

public struct OpenCodeCostProvider: ProviderFetcher {
    public let id = "opencode"
    public let displayName = "OpenCode"
    public let description = "Local OpenCode session ledger: tokens and models.dev-priced cost"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    /// 永久每日归档（每个 home 一张，按 homeDirectory 区分以隔离测试 / 多配置）。
    static let archive = OpenCodeUsageArchiveStore()
    /// 独立明细账本（message 级，按 message.id 去重增量），issue #67 的持久真相源。
    static let ledger = OpenCodeLedgerStore()
    static let defaultScanDays = 30

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()
        let todayKey = dayKey(now)

        // 首次（账本从未完成全量）触发全量扫描以回填账本全部明细；之后只扫窗口。
        let shouldImportFullHistory = await Self.ledger.consumeFullHistoryImportRequest(homeDirectory: homeDirectory)
        let sinceMillis: Int64? = shouldImportFullHistory ? nil : scanWindowStartMillis(now: now)

        // 1) 读库明细 → 账本合并（upsert 增量；OpenCode 未安装/版本过旧时跳过，账本仍有历史）。
        let dataDirectory = resolveDataDirectory()
        if let dataDirectory {
            let snapshotPath = try makeDatabaseSnapshot(dataDirectory: dataDirectory)
            defer { cleanupDatabaseSnapshot(snapshotPath) }
            let messageRows = try fetchMessageRows(databasePath: snapshotPath, sinceMillis: sinceMillis)
            let decoder = JSONDecoder()
            var entries: [OpenCodeLedgerEntry] = []
            entries.reserveCapacity(messageRows.count)
            for messageRow in messageRows {
                guard let entry = parseLedgerEntry(messageRow, decoder: decoder) else { continue }
                entries.append(entry)
            }
            await Self.ledger.merge(
                homeDirectory: homeDirectory,
                newEntries: entries,
                completedFullHistory: shouldImportFullHistory
            )
        }
        relieveMallocPressure()

        // 2) 账本聚合 → 冻结归档：昨日前首写冻结、今天从账本累积覆盖（删除会话后账本不删，统计不丢）。
        let ledgerEntries = await Self.ledger.allEntries(homeDirectory: homeDirectory)
        let sessionIds = Set(ledgerEntries.map { $0.sessionId })
        let computed = OpenCodeLedgerStore.aggregateDays(ledgerEntries)
        let dbDays = await Self.archive.freeze(
            homeDirectory: homeDirectory,
            computed: computed,
            todayKey: todayKey,
            completedFullHistory: shouldImportFullHistory
        )
        // 3) 合并全局统一代理用量（来自代理日志永久归档，模型键同口径 `aiusage-<slug>/<model>`，
        //    同节点同模型与 db 直连自动并入同一行；db 侧已排除裸全局 provider，两源互斥不双计）。
        //    即使本地 db 为空，只要有代理用量也照常呈现。
        let days = mergeProxyDays(into: dbDays)
        guard !days.isEmpty else {
            throw ProviderError("no_usage_data", "No OpenCode usage recorded (opencode.db not found or empty; requires OpenCode >= 1.2)")
        }

        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today = days[todayKey] ?? .empty
        let currentWeek = aggregateDays(days) { weekRange.dayKeys.contains($0) }
        let currentMonth = aggregateDays(days) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(days) { _ in true }

        let fallbackDays = max(days.count, Self.defaultScanDays)
        let archiveDayCount = archivedDayCount(days, now: now, fallback: fallbackDays)
        let overallRangeLabel = archivedRangeLabel(days, fallback: "Last \(Self.defaultScanDays) days")

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        // 冻结归档无小时粒度 → hourly 留空，统计页按日呈现（与 Codex 一致）。
        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: days, now: now, dayCount: archiveDayCount)))

        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.sessionCount"] = AnyCodable(sessionIds.count)

        func encodeModelBreakdown(_ agg: CodexAggregateBucket) -> [AnyCodable] {
            let sorted = agg.models.values.sorted {
                if $0.estimatedCostUsd != $1.estimatedCostUsd { return $0.estimatedCostUsd > $1.estimatedCostUsd }
                return $0.totalTokens > $1.totalTokens
            }
            let totalCost = agg.estimatedCostUsd
            let totalTokens = agg.totalTokens
            return sorted.map { model -> AnyCodable in
                let pct = totalCost > 0
                    ? roundUsd(model.estimatedCostUsd / totalCost * 100)
                    : (totalTokens > 0 ? roundUsd(Double(model.totalTokens) / Double(totalTokens) * 100) : 0)
                return AnyCodable([
                    "model": AnyCodable(model.model),
                    "totalTokens": AnyCodable(model.totalTokens),
                    "inputTokens": AnyCodable(model.inputTokens),
                    "outputTokens": AnyCodable(model.outputTokens),
                    "cacheReadTokens": AnyCodable(model.cacheReadTokens),
                    "cacheCreateTokens": AnyCodable(model.cacheCreateTokens),
                    "estimatedCostUsd": AnyCodable(roundUsd(model.estimatedCostUsd)),
                    "estimatedCostDisplay": AnyCodable(formatCurrency(roundUsd(model.estimatedCostUsd))),
                    "percentage": AnyCodable(pct)
                ] as [String: AnyCodable])
            }
        }

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(days.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let daily = trailingDailyTimeline(bucketsByDay: days, now: now, dayCount: archiveDayCount, model: modelName)
            guard !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable([AnyCodable]()),
                "daily": AnyCodable(encodeTimeline(daily, includeDetail: true))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        var source = SourceInfo(mode: "auto", type: "opencode-session-db")
        source.roots = dataDirectory.map { [$0] } ?? []
        usage.source = source
        return usage
    }

    func relieveMallocPressure() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(nil, Int.max)
        #endif
    }
}
