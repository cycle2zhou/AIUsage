import Foundation
import os.log

private let openCodeCallLedgerLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeCallLedger")

// MARK: - OpenCode Call Ledger Store
// 「调用分析」OpenCode 源的明细账本（issue #67 的调用分析部分）。
// 解决「删除 opencode 会话后，工具/MCP/Skill 调用次数统计丢失」。
//
// 数据源：opencode.db 的 `part` 表。message 删除会对 part 做级联删除（onDelete: cascade），
// 因此删 session 后 part 行消失，实时重扫拿不到 → 今天的调用次数减少。
// 本账本把每条 tool part（按 `part.id`，即 `prt_xxx`）持久化，扫描时按 id upsert、
// 读不到的不删，从而在 opencode 侧删会话后仍保留已记录的调用明细。
//
// 语义：
// - 本次扫描读到的 part 按 `id` upsert（覆盖旧值，处理 part 状态从 running→completed 的更新）；
// - 账本里本次读不到的 part 不删（处理「删除会话」不丢账）；
// - 首次启动做一次「全量历史导入」（fullHistoryImportedAt 标记），之后从
//   lastSuccessfulScanMillis 游标带安全重叠补采，而不是固定只扫今天；
// - 只有本次 DB 快照创建、查询、解析全成功（scanSucceeded）才推进游标与全量标记。
//
// 聚合：`aggregate` 把明细条目还原为「日 × 类别 × 名称(× server)」的 CallAnalyticsEntry，
// 与实时 CallEventAccumulator 口径一致（count / outcomeKnownCount / successCount /
// durationSampleCount / durationMsTotal）。
//
// 持久化（永久，放 ~/.config/aiusage 避免被系统磁盘清理）:
//   <home>/.config/aiusage/usage-archive/opencode-call-ledger-v<version>.json
//
// 线程：本类仅由 CallAnalyticsEngine（actor）持有并访问，访问被引擎 actor 串行化，
// 故与 CallAnalyticsArchiveStore 一样无需自身加锁。

/// 一条 OpenCode 工具调用明细（对应 part 表的一行 tool part）。
struct OpenCodeCallLedgerEntry: Codable, Sendable, Equatable {
    /// part 表主键（`prt_xxx`），稳定唯一去重键。
    let partId: String
    /// yyyy-MM-dd（本地时区），由 part.time_created 派生。
    let dayKey: String
    /// 调用类别（mcp / skill / builtin / webSearch / other）。
    let kind: CallKind
    /// 展示名：MCP=`server/tool`，Skill=技能名，其它=工具名。
    let name: String
    /// 仅 MCP 有值。
    let server: String?
    /// 成功/失败（nil = 无结果信号，如 pending/running）。
    let success: Bool?
    /// 耗时（毫秒），缺失或非法为 nil。
    let durationMs: Double?
}

/// 账本文件结构。
struct OpenCodeCallLedger: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var entries: [String: OpenCodeCallLedgerEntry]
    var fullHistoryImportedAt: String?
    /// 最后一次成功扫描时间（epoch 毫秒）。作为增量补采游标：下次从该位置带安全重叠向前扫，
    /// 而不是固定扫「今天」，从而补回跨日漏采（如 23:xx 产生、00:xx 才首次同步的调用）。
    /// nil = 尚未成功扫描过（或旧账本无此字段），需回退到全量或请求窗口。
    var lastSuccessfulScanMillis: Int64?
}

final class OpenCodeCallLedgerStore {
    static let artifactVersion = 1

    private let homeDirectory: String
    private var cached: OpenCodeCallLedger?

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    /// 是否已完成全量历史导入。false → 引擎应先扫全历史以冻结所有过去日。
    var fullHistoryImported: Bool {
        load().fullHistoryImportedAt != nil
    }

    /// 最后一次成功扫描时间。nil = 尚未成功扫描过。
    var lastSuccessfulScanDate: Date? {
        guard let millis = load().lastSuccessfulScanMillis else { return nil }
        return Date(timeIntervalSince1970: Double(millis) / 1000)
    }

    /// 合并本次扫描到的明细：按 partId upsert，账本里读不到的不删。
    /// `scanSucceeded` 为 true 时才推进「全量导入完成」标记与补采游标；
    /// 失败（DB 快照/查询失败、目录不可用）保留原状态，下次重试。
    /// 返回合并后的全部明细（含被删除会话的历史）。
    @discardableResult
    func merge(newEntries: [OpenCodeCallLedgerEntry], scanSucceeded: Bool) -> [OpenCodeCallLedgerEntry] {
        var ledger = load()
        var changed = false

        for entry in newEntries {
            if ledger.entries[entry.partId] != entry {
                ledger.entries[entry.partId] = entry
                changed = true
            }
        }

        if scanSucceeded {
            if ledger.fullHistoryImportedAt == nil {
                ledger.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
                changed = true
            }
            let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
            if ledger.lastSuccessfulScanMillis != nowMillis {
                ledger.lastSuccessfulScanMillis = nowMillis
                changed = true
            }
        }

        if changed {
            ledger.updatedAt = SharedFormatters.iso8601String(from: Date())
            cached = ledger
            save(ledger)
        } else {
            cached = ledger
        }
        return Array(ledger.entries.values)
    }

    /// 账本全部明细（含被删除会话的历史）。
    func allEntries() -> [OpenCodeCallLedgerEntry] {
        Array(load().entries.values)
    }

    /// 把明细条目聚合为「日 × 类别 × 名称(× server)」的计数条目，口径与实时 CallEventAccumulator 一致。
    static func aggregate(_ entries: [OpenCodeCallLedgerEntry]) -> [CallAnalyticsEntry] {
        struct Key: Hashable {
            let kind: CallKind
            let name: String
            let server: String?
            let dayKey: String
        }
        struct Agg {
            var count = 0
            var outcomeKnown = 0
            var success = 0
            var durationSamples = 0
            var durationMsTotal = 0.0
        }

        var counts: [Key: Agg] = [:]
        for entry in entries {
            let key = Key(kind: entry.kind, name: entry.name, server: entry.server, dayKey: entry.dayKey)
            var agg = counts[key] ?? Agg()
            agg.count += 1
            if let success = entry.success {
                agg.outcomeKnown += 1
                if success { agg.success += 1 }
            }
            if let durationMs = entry.durationMs, durationMs >= 0 {
                agg.durationSamples += 1
                agg.durationMsTotal += durationMs
            }
            counts[key] = agg
        }

        return counts.map { key, agg in
            CallAnalyticsEntry(
                source: .opencode,
                kind: key.kind,
                name: key.name,
                server: key.server,
                agent: nil,
                dayKey: key.dayKey,
                count: agg.count,
                outcomeKnownCount: agg.outcomeKnown,
                successCount: agg.success,
                durationSampleCount: agg.durationSamples,
                durationMsTotal: agg.durationMsTotal
            )
        }
    }

    // MARK: - Disk

    private func load() -> OpenCodeCallLedger {
        if let cached { return cached }

        if let data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory)),
           let decoded = try? JSONDecoder().decode(OpenCodeCallLedger.self, from: data),
           decoded.version == Self.artifactVersion {
            cached = decoded
            return decoded
        }

        let fresh = OpenCodeCallLedger(version: Self.artifactVersion, updatedAt: "", entries: [:], fullHistoryImportedAt: nil, lastSuccessfulScanMillis: nil)
        cached = fresh
        return fresh
    }

    private func save(_ ledger: OpenCodeCallLedger) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: url, options: .atomic)
        } catch {
            openCodeCallLedgerLog.warning("Failed to save opencode call ledger: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("opencode-call-ledger-v\(artifactVersion).json")
    }
}
