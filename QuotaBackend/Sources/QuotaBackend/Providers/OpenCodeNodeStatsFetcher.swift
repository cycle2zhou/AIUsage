import Foundation
import os.log

// MARK: - OpenCode Node Stats Fetcher
// 受管节点（providerID 以 aiusage 开头）的用量统计与最近请求明细，供管理页展示。
// 数据来源: opencode.db message 表（临时快照 + READONLY，复用 OpenCodeCostProvider 机制）。
// 工作方式: SQL LIKE 预过滤受管 providerID 行 → JSON 防御解析 → 按 providerID 聚合 +
//          截取最近 N 条明细。费用为 OpenCode 预计算冻结值，与用量统计页同一口径，
//          不与代理日志混账（代理日志仅观测成功率/时延）。

private let openCodeNodeStatsLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeNodeStats")

public enum OpenCodeNodeStatsFetcher {

    // MARK: - Output Types

    /// 单个受管节点（providerID）的全量聚合。
    public struct NodeStats: Sendable {
        public var requestCount = 0
        public var inputTokens = 0
        public var outputTokens = 0
        public var cacheReadTokens = 0
        public var cacheCreateTokens = 0
        public var totalTokens = 0
        public var costUsd: Double = 0
        public var lastUsedAt: Date?
    }

    /// 一条 assistant 消息的展示明细（新→旧）。
    public struct RecentMessage: Sendable, Identifiable {
        public let id: String
        public let date: Date
        public let providerID: String
        public let modelID: String
        public let inputTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreateTokens: Int
        public let costUsd: Double
        /// data.time.completed - created；任一缺失为 nil。
        public let durationMs: Int?

        public var totalTokens: Int {
            inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheCreateTokens
        }
    }

    public struct Snapshot: Sendable {
        public var statsByProviderID: [String: NodeStats] = [:]
        /// 全部受管节点合并的最近明细（新→旧，封顶 recentLimit）。
        public var recentMessages: [RecentMessage] = []
        public var generatedAt = Date()
    }

    // MARK: - Change Detection

    /// 轻量变更指纹：opencode.db / -wal 的 mtime+size 拼接。
    /// 管理页轮询比对，仅在库真正变化时才触发整库快照扫描。
    public static func databaseFingerprint(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let provider = OpenCodeCostProvider(homeDirectory: homeDirectory, environment: environment)
        guard let dataDirectory = provider.resolveDataDirectory() else { return nil }
        let dbPath = (dataDirectory as NSString).appendingPathComponent(OpenCodeCostProvider.databaseFilename)

        var parts: [String] = []
        for path in [dbPath, dbPath + "-wal"] {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs[.size] as? Int) ?? 0
            parts.append("\(mtime):\(size)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    // MARK: - Fetch

    /// 同步阻塞读取（调用方负责放后台任务）。opencode.db 不存在时返回 nil。
    public static func fetch(
        providerIDPrefix: String = "aiusage",
        recentLimit: Int = 200,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> Snapshot? {
        let provider = OpenCodeCostProvider(homeDirectory: homeDirectory, environment: environment)
        guard let dataDirectory = provider.resolveDataDirectory() else { return nil }

        let snapshotPath = try provider.makeDatabaseSnapshot(dataDirectory: dataDirectory)
        defer { provider.cleanupDatabaseSnapshot(snapshotPath) }

        let storage = resolveOpenCodeStorage(homeDirectory: homeDirectory, environment: environment)
        let messages = try storage.fetchMessages(
            dbPath: snapshotPath,
            query: OpenCodeMessageQuery(dataLike: "%\(providerIDPrefix)%")
        )

        var snapshot = Snapshot()
        for message in messages {
            guard let providerID = message.providerID,
                  providerID.hasPrefix(providerIDPrefix) else {
                continue
            }
            // 全局统一代理流量记在裸 `aiusage`（无对应节点 slug，永远映射不到任何节点卡片）。
            // 其用量/费用已由代理日志（OpenCodeProxyRuntime.globalStats）按节点定价归因，
            // 这里跳过避免产生孤儿桶（per-node 受管键恒为 `aiusage-<slug>`，不受影响）。
            if providerID == OpenCodeCostProvider.globalProxyProviderID { continue }

            let input = message.inputTokens
            let output = message.outputTokens
            let reasoning = message.reasoningTokens
            let cacheRead = message.cacheReadTokens
            let cacheCreate = message.cacheCreateTokens
            let cost = message.costUsd
            let total = message.totalTokens
            guard total > 0 || cost > 0 else { continue }

            let date = Date(timeIntervalSince1970: Double(message.timeCreatedMillis) / 1000)

            var stats = snapshot.statsByProviderID[providerID] ?? NodeStats()
            stats.requestCount += 1
            stats.inputTokens += input
            stats.outputTokens += output
            stats.cacheReadTokens += cacheRead
            stats.cacheCreateTokens += cacheCreate
            stats.totalTokens += total
            stats.costUsd += cost
            if stats.lastUsedAt.map({ date > $0 }) ?? true {
                stats.lastUsedAt = date
            }
            snapshot.statsByProviderID[providerID] = stats

            if snapshot.recentMessages.count < recentLimit {
                snapshot.recentMessages.append(RecentMessage(
                    id: message.id,
                    date: date,
                    providerID: providerID,
                    modelID: message.modelID ?? "unknown",
                    inputTokens: input,
                    outputTokens: output,
                    reasoningTokens: reasoning,
                    cacheReadTokens: cacheRead,
                    cacheCreateTokens: cacheCreate,
                    costUsd: cost,
                    durationMs: message.durationMs
                ))
            }
        }

        openCodeNodeStatsLog.debug("OpenCode node stats: \(snapshot.statsByProviderID.count, privacy: .public) providers, \(snapshot.recentMessages.count, privacy: .public) recent rows")
        return snapshot
    }

}
