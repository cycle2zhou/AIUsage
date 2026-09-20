import Foundation
import os.log

private let openCodeLedgerLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeLedger")

// MARK: - OpenCode Ledger Store
// OpenCode 本地会话用量的「独立明细账本」（issue #67）。
// 与 usage-archive 的「日聚合冻结」不同，本账本按 message 级明细持久化，
// 以 opencode.db message.id 为主键做 upsert，从而在 opencode 侧删除会话 / 清空历史后，
// 已记录的 token/cost 明细仍可追溯、不丢失。
//
// 语义：
// - upsert：本次扫描读到的 message（按 id）覆盖旧值——处理 opencode 流式过程中 token 数的渐进更新。
// - 保留：本次扫描读不到的 message（opencode 侧已删除，或超出扫描窗口）不从账本删除——删除不丢账。
//
// 持久化（永久、放 ~/.config/aiusage 避免被系统清理）:
//   <home>/.config/aiusage/usage-archive/opencode-ledger-v<version>.json
// 与 usage-archive 同目录但独立文件，避免污染 Codex/Claude 共享的 CodexUsageArchive 结构。

/// 一条 assistant 消息的完整用量明细（满足 issue #67「明细可追溯」：时间/模型/各类型 token/cost）。
struct OpenCodeLedgerEntry: Codable, Sendable, Equatable {
    /// opencode.db message.id（text 主键，如 `msg_xxx`），账本去重键。
    let messageId: String
    let sessionId: String
    /// 消息创建时间（epoch 毫秒，来自 message.time_created）。
    let timeCreatedMillis: Int64
    /// 归属日（yyyy-MM-dd，解析时按 provider 时区固定，避免时区漂移）。
    let dayKey: String
    /// 模型名口径 `providerID/modelID`。
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let cacheReadTokens: Int
    let cacheCreateTokens: Int
    let totalTokens: Int
    /// models.dev 定价的冻结成本（订阅渠道恒 0，非「未定价」）。
    let estimatedCostUsd: Double

    func asCodexRow() -> CodexRow {
        CodexRow(
            dayKey: dayKey,
            model: model,
            inputTokens: inputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreateTokens: cacheCreateTokens,
            outputTokens: outputTokens,
            totalTokens: totalTokens,
            estimatedCostUsd: estimatedCostUsd
        )
    }
}

/// 账本文件结构（version 1）。
struct OpenCodeLedger: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var entries: [String: OpenCodeLedgerEntry]
    var fullHistoryImportedAt: String?
    /// 最后一次成功扫描时间（epoch 毫秒），作为增量补采游标。nil = 尚未成功扫描过。
    var lastSuccessfulScanMillis: Int64?
    /// 旧 usage-archive 迁移后的「残差」（max(旧归档 - 迁移时账本快照, 0)，按 day+model 冻结）。
    /// 迁移后展示恒为「当前账本 + 残差」，完全重叠不重复、完全删除不丢、同日部分删除也不丢。nil = 尚未迁移。
    var legacyResidualDays: [String: CodexAggregateBucket]?
    /// 旧 usage-archive 迁移完成时间（ISO8601）。nil = 尚未迁移。
    var legacyArchiveMigratedAt: String?
}

actor OpenCodeLedgerStore {
    static let artifactVersion = 2

    private var ledgers: [String: OpenCodeLedger] = [:]
    private var loaded: Set<String> = []

    /// 首次返回 true（触发一次全量扫描以回填账本全部明细），完成后恒 false。
    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 最后一次成功扫描时间（epoch 毫秒）。nil = 尚未成功扫描过（或旧账本无此字段）。
    func lastSuccessfulScanMillis(homeDirectory: String) -> Int64? {
        load(homeDirectory).lastSuccessfulScanMillis
    }

    /// 按 messageId upsert 合并本次读到的明细；账本中读不到的条目保留（删除不丢）。
    /// `scanSucceeded` 为 true 时才推进「全量导入完成」标记与补采游标；
    /// 失败（DB 快照/查询失败、目录不可用）保留原状态，下次重试。
    /// 返回合并后的全部明细，供调用方聚合与 sessionCount 统计。
    @discardableResult
    func merge(
        homeDirectory: String,
        newEntries: [OpenCodeLedgerEntry],
        scanSucceeded: Bool
    ) -> [OpenCodeLedgerEntry] {
        var ledger = load(homeDirectory)
        var changed = false

        for entry in newEntries {
            if ledger.entries[entry.messageId] != entry {
                ledger.entries[entry.messageId] = entry
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
            ledgers[homeDirectory] = ledger
            save(homeDirectory, ledger)
        } else {
            ledgers[homeDirectory] = ledger
        }
        return Array(ledger.entries.values)
    }

    /// 读取账本全部明细（不触发写）。
    func allEntries(homeDirectory: String) -> [OpenCodeLedgerEntry] {
        Array(load(homeDirectory).entries.values)
    }

    /// 旧 usage-archive 是否尚未迁移（幂等判断）。
    func needsLegacyArchiveMigration(homeDirectory: String) -> Bool {
        load(homeDirectory).legacyArchiveMigratedAt == nil
    }

    /// 账本是否已完成全量历史导入（全量导入成功是旧归档迁移的前置条件——只有账本回填了全部
    /// 明细后，用「迁移时账本快照」算出的残差才完整，否则会把未回填的删会话记录错当成残差）。
    func isFullHistoryImported(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt != nil
    }

    /// 一次性把旧 usage-archive 迁入账本为「残差」（幂等，迁移完成状态持久化）：
    /// `residual = max(legacy - ledgerSnapshot, 0)`，按 day+model 逐字段相减钳制。
    /// 迁移后展示恒为「当前账本 + 残差」：完全重叠不重复、完全删除不丢、同日部分删除也不丢；
    /// 迁移后新记录继续由账本正常增量。今天由账本实时维护，不参与残差（旧归档今天快照会过期）。
    func migrateLegacyArchiveIfNeeded(
        homeDirectory: String,
        legacyDays: [String: CodexAggregateBucket],
        ledgerSnapshotDays: [String: CodexAggregateBucket],
        todayKey: String
    ) {
        var ledger = load(homeDirectory)
        guard ledger.legacyArchiveMigratedAt == nil else { return }

        let residual = Self.residualDays(
            legacyDays: legacyDays,
            ledgerSnapshotDays: ledgerSnapshotDays,
            todayKey: todayKey
        )

        ledger.legacyResidualDays = residual
        ledger.legacyArchiveMigratedAt = SharedFormatters.iso8601String(from: Date())
        ledger.updatedAt = SharedFormatters.iso8601String(from: Date())
        ledgers[homeDirectory] = ledger
        save(homeDirectory, ledger)
    }

    /// 已迁入的残差（冻结快照）。展示时叠加到账本聚合之上，删会话独有部分据此保留、重叠部分不双计。
    func legacyResidualDays(homeDirectory: String) -> [String: CodexAggregateBucket] {
        load(homeDirectory).legacyResidualDays ?? [:]
    }

    /// 计算旧归档相对「迁移时账本快照」的残差：`max(legacy - ledgerSnapshot, 0)`。
    /// 按 day+model 逐字段相减钳制（input/output/cacheRead/cacheCreate/totalTokens/cost 各自独立），
    /// 日汇总（totalTokens/cost）从模型残差重新聚合，usageRows 桶级相减钳制。今天不参与。
    static func residualDays(
        legacyDays: [String: CodexAggregateBucket],
        ledgerSnapshotDays: [String: CodexAggregateBucket],
        todayKey: String
    ) -> [String: CodexAggregateBucket] {
        var residual: [String: CodexAggregateBucket] = [:]
        for (day, legacyBucket) in legacyDays where day != todayKey {
            let ledgerBucket = ledgerSnapshotDays[day] ?? .empty
            var residualBucket = CodexAggregateBucket.empty

            for (modelName, legacyModel) in legacyBucket.models {
                let ledgerModel = ledgerBucket.models[modelName] ?? CodexModelAggregate(model: modelName)
                let input = max(legacyModel.inputTokens - ledgerModel.inputTokens, 0)
                let output = max(legacyModel.outputTokens - ledgerModel.outputTokens, 0)
                let cacheRead = max(legacyModel.cacheReadTokens - ledgerModel.cacheReadTokens, 0)
                let cacheCreate = max(legacyModel.cacheCreateTokens - ledgerModel.cacheCreateTokens, 0)
                let total = max(legacyModel.totalTokens - ledgerModel.totalTokens, 0)
                let cost = max(legacyModel.estimatedCostUsd - ledgerModel.estimatedCostUsd, 0)
                if total == 0, cost == 0, input == 0, output == 0, cacheRead == 0, cacheCreate == 0 {
                    continue
                }
                residualBucket.models[modelName] = CodexModelAggregate(
                    model: modelName,
                    totalTokens: total,
                    inputTokens: input,
                    outputTokens: output,
                    cacheReadTokens: cacheRead,
                    cacheCreateTokens: cacheCreate,
                    unpricedRequests: 0,
                    estimatedCostUsd: cost
                )
                residualBucket.totalTokens += total
                residualBucket.estimatedCostUsd += cost
            }

            residualBucket.usageRows = max(legacyBucket.usageRows - ledgerBucket.usageRows, 0)

            if !residualBucket.models.isEmpty || residualBucket.usageRows > 0 {
                residual[day] = residualBucket
            }
        }
        return residual
    }

    /// 从明细聚合日桶（复用 CodexAggregateBucket.record）。
    static func aggregateDays(_ entries: [OpenCodeLedgerEntry]) -> [String: CodexAggregateBucket] {
        var days: [String: CodexAggregateBucket] = [:]
        for entry in entries {
            days[entry.dayKey, default: .empty].record(row: entry.asCodexRow())
        }
        return days
    }

    // MARK: Disk

    private func load(_ homeDirectory: String) -> OpenCodeLedger {
        if let ledger = ledgers[homeDirectory], loaded.contains(homeDirectory) { return ledger }
        loaded.insert(homeDirectory)

        if let data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory)),
           let decoded = try? JSONDecoder().decode(OpenCodeLedger.self, from: data),
           decoded.version == Self.artifactVersion {
            ledgers[homeDirectory] = decoded
            return decoded
        }

        let fresh = OpenCodeLedger(version: Self.artifactVersion, updatedAt: "", entries: [:])
        ledgers[homeDirectory] = fresh
        return fresh
    }

    private func save(_ homeDirectory: String, _ ledger: OpenCodeLedger) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(ledger)
            try data.write(to: url, options: .atomic)
        } catch {
            openCodeLedgerLog.warning("Failed to save OpenCode ledger: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("opencode-ledger-v\(artifactVersion).json")
    }
}
