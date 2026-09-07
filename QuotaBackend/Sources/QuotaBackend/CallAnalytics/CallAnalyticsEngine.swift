import Foundation

// MARK: - Call Analytics Engine
// 调用分析的后台编排：运行三家来源 + 已装清单探测，合并为一份快照。
// 在 actor 内串行执行（重活在后台线程，不阻塞主线程）；无成本冻结，整份可重建。
// 设计见 docs/CALL_ANALYTICS_DESIGN.md。

public actor CallAnalyticsEngine {
    public static let shared = CallAnalyticsEngine()

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]
    /// 永久每日冻结归档（issue #32）：删 session 后历史调用统计不丢。仅本 actor 访问，串行安全。
    private let archive: CallAnalyticsArchiveStore
    /// OpenCode 明细账本（issue #67 调用分析部分）：按 part.id upsert、读不到的不删，删 session 后调用明细不丢。
    private let opencodeLedger: OpenCodeCallLedgerStore

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
        self.archive = CallAnalyticsArchiveStore(homeDirectory: homeDirectory)
        self.opencodeLedger = OpenCodeCallLedgerStore(homeDirectory: homeDirectory)
    }

    /// 计算调用分析快照。
    /// - Parameters:
    ///   - rangeKey: 时间范围标识（`today`/`week`/`month`/`all` 或自定义键），仅作快照/缓存身份用。
    ///   - cutoff: 起始日界（含）。`nil` = 不设下限（全部历史）。文件预筛 + 按事件日期精确过滤都用它。
    ///   - end: 结束日界（含）。`nil` = 不设上限（到现在）。日历口径恒为 `nil`，仅自定义区间用到。
    ///
    /// 注：`cutoff` 既用于「按文件 mtime / 库时间」预筛跳过窗外文件（省 IO），也用于对**每条事件**按
    /// `dayKey` 精确过滤——后者保证「今日」只含今天的调用，不被跨天会话的旧调用串味。
    public func computeSnapshot(rangeKey: String, cutoff: Date?, end: Date? = nil) -> CallAnalyticsSnapshot {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let todayKey = clock.dayKey(Date())

        // 先建清单：OpenCode 已装 MCP server 名要回灌给其事件源做精确前缀匹配。
        // 清单（已装技能/MCP）读本地目录与配置，与会话无关，不需冻结。
        let inventory = CallAnalyticsInventory(homeDirectory: homeDirectory)
        let installedSkills = inventory.installedSkills()
        let installedMCP = inventory.installedMCPServers()
        let openCodeServers = Set(installedMCP.filter { $0.source == .opencode }.map(\.name))

        // 首次：扫全历史以冻结所有过去日（之后只扫请求窗口即可，省 IO）。
        let needsFullImport = !archive.fullHistoryImported
        let scanCutoff: Date? = needsFullImport ? nil : cutoff

        let claude = ClaudeCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment)
            .collect(cutoff: scanCutoff)
        let codex = CodexCallEventSource(homeDirectory: homeDirectory, timeZone: timeZone, environment: environment)
            .collect(cutoff: scanCutoff)
        let opencodeRaw = OpenCodeCallEventSource(
            homeDirectory: homeDirectory, timeZone: timeZone, environment: environment,
            knownMCPServers: openCodeServers
        ).collect(cutoff: scanCutoff)

        // OpenCode 明细账本：issue #67 调用分析部分。按 part.id upsert、读不到的不删，
        // 使删除 opencode 会话后已记录的调用明细不丢；再从账本聚合回计数条目。
        let opencodeLedgerEntries = opencodeLedger.merge(newEntries: opencodeRaw.entries, completedFullHistory: needsFullImport)
        let opencodeEntries = OpenCodeCallLedgerStore.aggregate(opencodeLedgerEntries)

        // 实时结果按日分桶（entries 自带 dayKey；Claude 的 agentInvocations 已按天归属）。
        var computed: [String: CallAnalyticsDayBucket] = [:]
        for entry in claude.entries { computed[entry.dayKey, default: .empty].entries.append(entry) }
        for entry in codex.entries { computed[entry.dayKey, default: .empty].entries.append(entry) }
        for entry in opencodeEntries { computed[entry.dayKey, default: .empty].entries.append(entry) }
        for (day, invs) in claude.agentInvocationsByDay {
            computed[day, default: .empty].agentInvocations.append(contentsOf: invs)
        }

        // 冻结合并 → 拿回全量归档日（含被删 session 的历史日）。
        let frozenDays = archive.freeze(computed: computed, todayKey: todayKey, completedFullHistory: needsFullImport)

        // 从归档取请求范围内的数据展示：删 session 后过去日仍在，今天随实时刷新。
        let lowerKey = cutoff.map { clock.dayKey($0) }
        let upperKey = end.map { clock.dayKey($0) }
        var entries: [CallAnalyticsEntry] = []
        var agentTotals: [AgentInvocationKey: Int] = [:]
        for (day, bucket) in frozenDays {
            if let lowerKey, day < lowerKey { continue }
            if let upperKey, day > upperKey { continue }
            entries.append(contentsOf: bucket.entries)
            for inv in bucket.agentInvocations {
                agentTotals[AgentInvocationKey(source: inv.source, agent: inv.agent), default: 0] += inv.count
            }
        }
        let agentInvocations = agentTotals.map {
            AgentInvocationCount(source: $0.key.source, agent: $0.key.agent, count: $0.value)
        }

        // 各源对外展示的「调用次数」以归档展示条目为准，避免页脚 M 次调用与上方 KPI 对不上；
        // available / filesScanned / errorCode 沿用本次实时扫描状态。
        let rawStatuses = [claude.status, codex.status, opencodeRaw.status]
        let statuses = rawStatuses.map { status -> CallSourceStatus in
            let count = entries.filter { $0.source == status.source }.reduce(0) { $0 + $1.count }
            return CallSourceStatus(
                source: status.source,
                available: status.available,
                eventCount: count,
                filesScanned: status.filesScanned,
                errorCode: status.errorCode
            )
        }

        return CallAnalyticsSnapshot(
            generatedAt: Date(),
            rangeKey: rangeKey,
            entries: entries,
            installedSkills: installedSkills,
            installedMCPServers: installedMCP,
            agentInvocations: agentInvocations,
            sources: statuses
        )
    }

    /// agentInvocations 跨日聚合键。
    private struct AgentInvocationKey: Hashable {
        let source: CallSourceKind
        let agent: String
    }
}
