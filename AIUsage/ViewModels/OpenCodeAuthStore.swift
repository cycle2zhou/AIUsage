import Foundation
import os.log
import QuotaBackend

// MARK: - OpenCode Auth Store
// 管理 OpenCode 凭据：v1 存 ~/.local/share/opencode/auth.json，v2 存 opencode.db 的 credential 表。
// 具体位置由 resolveOpenCodeStorage() 按本机版本路由（见 QuotaBackend.OpenCodeStorage）。
// 只接管 `aiusage*` 键（OpenCodeConfigManager.isManagedProviderKey）；用户自己 auth login 存的
// 其他 provider 凭据原样保留。

private let openCodeAuthLog = Logger(subsystem: "com.aiusage.desktop", category: "OpenCodeAuth")

final class OpenCodeAuthStore {
    static let shared = OpenCodeAuthStore()

    private let storage: OpenCodeStorage

    private init() {
        storage = resolveOpenCodeStorage()
    }

    /// 参与配置文件事务的凭据文件路径（v1 auth.json；v2 SQLite 表无需纳入）。
    var transactionPaths: [String] {
        storage.credentialFilePaths
    }

    /// 受管 provider 当前记录的 API Key。
    func managedAPIKey(forProviderId providerId: String) -> String? {
        storage.loadAllCredentials()[providerId]
    }

    /// 让受管凭据恰好等于 `credentials`：删除其余 `aiusage*` 项，写入给定项，非受管项保留。
    /// 返回是否全部写入成功——失败时调用方回退到把 key 内联进配置。
    @discardableResult
    func syncManagedCredentials(_ credentials: [String: String]) -> Bool {
        let existing = storage.loadAllCredentials()
        var allSucceeded = true
        for providerId in existing.keys where OpenCodeConfigManager.isManagedProviderKey(providerId) {
            if !storage.deleteCredential(providerID: providerId) {
                allSucceeded = false
            }
        }
        for (providerId, apiKey) in credentials where !apiKey.isEmpty {
            if !storage.upsertCredential(providerID: providerId, key: apiKey) {
                allSucceeded = false
            }
        }
        if !allSucceeded {
            openCodeAuthLog.error("Failed to sync managed credentials")
        }
        return allSucceeded
    }

    /// 清掉全部受管凭据（停用节点时调用）。
    @discardableResult
    func removeManagedCredentials() -> Bool {
        syncManagedCredentials([:])
    }
}
