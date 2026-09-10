import Foundation
import os.log

private let openCodeArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "OpenCodeUsageArchive")

// MARK: - OpenCode Usage Archive Store
// OpenCode 本地会话用量的「永久每日归档」。与 Codex 非代理归档同一冻结语义：
// - 「今天之前」的日期：首次写入后即冻结，之后重扫不再变动 → 历史不可篡改、删库不丢账。
// - 「今天」：每次扫描用当前 opencode.db 重算并覆盖；跨天后自然冻结。
// 与 Codex 非代理轨不同：OpenCode 每条消息自带 models.dev 定价的冻结成本，归档保留 cost。
//
// 持久化（永久、放 ~/.config/aiusage 避免被系统清理）:
//   <home>/.config/aiusage/usage-archive/opencode-usage-v<version>.json
// 复用 CodexUsageArchive 结构（fullHistoryImportedAt 标记一次性全量冻结）。

actor OpenCodeUsageArchiveStore {
    static let artifactVersion = 1

    private var archives: [String: CodexUsageArchive] = [:]
    private var loaded: Set<String> = []

    /// 首次返回 true（触发一次全量扫描以冻结所有历史日），完成后恒 false。
    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    /// 冻结合并：past(<today) 仅在缺失时首次写入；today 每次覆盖重算；已冻结的 past 保持不动。
    /// 返回合并后的全部归档日，供 costSummary 聚合。
    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        todayKey: String,
        completedFullHistory: Bool
    ) -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var changed = false

        for (day, bucket) in computed where !bucket.models.isEmpty {
            if day == todayKey {
                archive.days[day] = bucket
                changed = true
            } else if archive.days[day] == nil {
                archive.days[day] = bucket
                changed = true
            }
        }

        if computed[todayKey]?.models.isEmpty != false,
           archive.days.removeValue(forKey: todayKey) != nil {
            changed = true
        }

        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[homeDirectory] = archive
            save(homeDirectory, archive)
        } else {
            archives[homeDirectory] = archive
        }
        return archive.days
    }

    // MARK: Disk

    /// 只读旧归档全部日（一次性迁移用，不触发写）。
    func days(homeDirectory: String) -> [String: CodexAggregateBucket] {
        load(homeDirectory).days
    }

    private func load(_ homeDirectory: String) -> CodexUsageArchive {
        if let archive = archives[homeDirectory], loaded.contains(homeDirectory) { return archive }
        loaded.insert(homeDirectory)

        if let data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory)),
           let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
           decoded.version == Self.artifactVersion {
            archives[homeDirectory] = decoded
            return decoded
        }

        let fresh = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
        archives[homeDirectory] = fresh
        return fresh
    }

    private func save(_ homeDirectory: String, _ archive: CodexUsageArchive) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            openCodeArchiveLog.warning("Failed to save OpenCode usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("opencode-usage-v\(artifactVersion).json")
    }
}
