import Foundation

// MARK: - OpenCode Message Parsing

extension OpenCodeCostProvider {

    /// 全局统一代理在 opencode.json 注入的受管 provider 键（与 App 端 OpenCodeConfigManager.globalProviderId 对齐）。
    /// 该 provider 下的 db 记录属全局模式流量——成本已走代理日志（PROXY_LOG → ProxyRequestLog/归档）计入，
    /// 这里排除以免在 OpenCode 用量/费用/热力图里被重复计数。per-node 受管键恒为 `aiusage-<slug>`，不受影响。
    static let globalProxyProviderID = "aiusage"

    func parseLedgerEntry(_ message: OpenCodeMessage) -> OpenCodeLedgerEntry? {
        // 全局统一代理流量（providerID == "aiusage"）已由代理日志计入，跳过避免重复计数。
        if message.providerID?.trimmingCharacters(in: .whitespacesAndNewlines) == Self.globalProxyProviderID {
            return nil
        }

        let totalTokens = message.totalTokens
        let cost = message.costUsd
        guard totalTokens > 0 || cost > 0 else { return nil }

        let createdAt = Date(timeIntervalSince1970: Double(message.timeCreatedMillis) / 1000)
        return OpenCodeLedgerEntry(
            messageId: message.id,
            sessionId: message.sessionId,
            timeCreatedMillis: message.timeCreatedMillis,
            dayKey: dayKey(createdAt),
            model: message.modelLabel,
            inputTokens: message.inputTokens,
            outputTokens: message.outputTokens,
            cacheReadTokens: message.cacheReadTokens,
            cacheCreateTokens: message.cacheCreateTokens,
            totalTokens: totalTokens,
            estimatedCostUsd: cost
        )
    }
}
