import Foundation
import Combine
import os.log
import QuotaBackend

// MARK: - Call Analytics Store
// 「调用分析」页的状态层：触发后台引擎计算、发布快照、并把结果缓存落盘以便冷启动即时展示。
// 无成本冻结需求，缓存可随时整份重建（见 docs/CALL_ANALYTICS_DESIGN.md）。

@MainActor
final class CallAnalyticsStore: ObservableObject {
    static let shared = CallAnalyticsStore()

    @Published private(set) var snapshot: CallAnalyticsSnapshot
    @Published private(set) var isRefreshing = false

    private let engine = CallAnalyticsEngine.shared
    private let log = Logger(subsystem: "com.aiusage.desktop", category: "CallAnalytics")
    private static let cacheSchemaVersion = CallAnalyticsSnapshot.currentSchemaVersion

    init() {
        snapshot = Self.loadCache() ?? .empty
        Self.pruneStaleCaches()
    }

    /// 重新解析并刷新（视图出现 / 手动刷新按钮 / 时间范围切换）。
    func refresh(rangeKey: String, cutoff: Date?, end: Date?) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result = await engine.computeSnapshot(rangeKey: rangeKey, cutoff: cutoff, end: end)
        snapshot = result
        Self.saveCache(result)
        log.debug("Call analytics refreshed: \(result.entries.count, privacy: .public) entries, range \(rangeKey, privacy: .public)")
    }

    // MARK: - Cache

    private static var cacheURL: URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/aiusage/cache", isDirectory: true)
        return base.appendingPathComponent("call-analytics-v\(cacheSchemaVersion).json")
    }

    private static func loadCache() -> CallAnalyticsSnapshot? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let snapshot = try? decoder.decode(CallAnalyticsSnapshot.self, from: data),
              snapshot.schemaVersion == cacheSchemaVersion else {
            return nil
        }
        return snapshot
    }

    private static func saveCache(_ snapshot: CallAnalyticsSnapshot) {
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    /// 删除旧 schema 版本遗留的缓存文件（call-analytics-v*.json，当前版本除外），避免无用文件堆积。
    private static func pruneStaleCaches() {
        let directory = cacheURL.deletingLastPathComponent()
        let current = cacheURL.lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for item in items where item.pathExtension == "json"
            && item.lastPathComponent.hasPrefix("call-analytics-v")
            && item.lastPathComponent != current {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
