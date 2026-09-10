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
}

actor OpenCodeLedgerStore {
    static let artifactVersion = 1

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
