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

    /// 独立明细账本（message 级，按 message.id 去重增量），issue #67 的持久真相源。
    /// 展示层用账本聚合 + 旧 usage-archive 一次性迁移的历史日（删会话独有），
    /// 旧归档在迁移完成后退役（避免「过去日冻结」阻止补采更新）。
    static let ledger = OpenCodeLedgerStore()
    /// 旧 usage-archive（升级前日归档），仅用于一次性迁移，迁移后退役。
    static let archive = OpenCodeUsageArchiveStore()
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

        // 首次（账本从未完成全量）触发全量扫描以回填账本全部明细；之后从上次成功游标带安全重叠补采。
        let shouldImportFullHistory = await Self.ledger.consumeFullHistoryImportRequest(homeDirectory: homeDirectory)
        let lastSuccessfulScanMillis = await Self.ledger.lastSuccessfulScanMillis(homeDirectory: homeDirectory)
        let sinceMillis = Self.scanSinceMillis(
            shouldImportFullHistory: shouldImportFullHistory,
            lastSuccessfulScanMillis: lastSuccessfulScanMillis,
            fallbackMillis: scanWindowStartMillis(now: now)
        )

        // 1) 读库明细 → 账本合并（upsert 增量；OpenCode 未安装/快照失败时不推进账本游标，下次重试）。
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
                scanSucceeded: true
            )
        }
        relieveMallocPressure()

        // 2) 账本聚合作为展示源（账本即真相源，含补采回填的历史）。
        let ledgerEntries = await Self.ledger.allEntries(homeDirectory: homeDirectory)
        let sessionIds = Set(ledgerEntries.map { $0.sessionId })
        let dbDays = OpenCodeLedgerStore.aggregateDays(ledgerEntries)

        // 3) 一次性把旧 usage-archive 的历史日迁入账本（幂等），迁移后旧归档退役：
        //    删会话独有的历史日保留在 legacyDays，账本聚合覆盖重叠日（不双计）。
        if await Self.ledger.needsLegacyArchiveMigration(homeDirectory: homeDirectory) {
            let archiveDays = await Self.archive.days(homeDirectory: homeDirectory)
            await Self.ledger.migrateLegacyArchiveIfNeeded(
                homeDirectory: homeDirectory,
                legacyDays: archiveDays,
                todayKey: todayKey
            )
        }
        let legacyDays = await Self.ledger.legacyDays(homeDirectory: homeDirectory)
        let mergedDays = legacyDays.merging(dbDays) { _, ledger in ledger }

        // 4) 合并全局统一代理用量（来自代理日志永久归档，模型键同口径 `aiusage-<slug>/<model>`，
        //    同节点同模型与 db 直连自动并入同一行；db 侧已排除裸全局 provider，两源互斥不双计）。
        //    即使本地 db 为空，只要有代理用量也照常呈现。
        let days = mergeProxyDays(into: mergedDays)
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

    /// 扫描窗口起点（epoch 毫秒）：全量 → nil；已有游标 → 游标带 24h 安全重叠补采；无游标 → 回退默认窗口。
    static func scanSinceMillis(
        shouldImportFullHistory: Bool,
        lastSuccessfulScanMillis: Int64?,
        fallbackMillis: Int64
    ) -> Int64? {
        if shouldImportFullHistory {
            return nil
        }
        if let lastScan = lastSuccessfulScanMillis {
            return lastScan - scanOverlapMillis
        }
        return fallbackMillis
    }

    static let scanOverlapMillis: Int64 = 24 * 3600 * 1000

    func relieveMallocPressure() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(nil, Int.max)
        #endif
    }
}
