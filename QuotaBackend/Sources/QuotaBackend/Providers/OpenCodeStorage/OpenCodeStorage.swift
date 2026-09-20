import Foundation
import SQLite3

// MARK: - OpenCode Storage（版本无关数据访问）
// 把 opencode v1/v2 的本地数据 schema 差异收敛到各自的 reader（OpenCodeV1Storage / OpenCodeV2Storage），
// 业务层（用量统计 / 节点统计 / 调用分析 / 凭据接管）只依赖本协议 + 统一领域模型，不感知版本。
// 新增 v3 时只需新增 OpenCodeV3Storage 文件并扩展 resolveOpenCodeStorage() 路由，不触碰 v1/v2 实现。

// MARK: - 领域模型

/// 一条 assistant 消息（reader 保证只返回 assistant：v1 解析后过滤 / v2 SQL 层过滤）。
public struct OpenCodeMessage: Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let timeCreatedMillis: Int64
    /// 归一化 providerID：v1 顶层 providerID / v2 model.providerID。
    public let providerID: String?
    /// 归一化 modelID：v1 顶层 modelID / v2 model.id。
    public let modelID: String?
    public let inputTokens: Int
    public let outputTokens: Int
    /// v2 独立 reasoning token；v1 恒 0。
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreateTokens: Int
    public let costUsd: Double
    /// data.time.completed - created（epoch 毫秒）；任一缺失为 nil。
    public let durationMs: Int?

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheCreateTokens
    }

    /// 模型名口径 `providerID/modelID`（保留 OpenCode 内部供应商维度）。
    public var modelLabel: String {
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (provider.isEmpty, model.isEmpty) {
        case (false, false): return "\(provider)/\(model)"
        case (true, false):  return model
        case (false, true):  return provider
        case (true, true):   return "unknown"
        }
    }
}

/// 一次工具调用（reader 从 v1 part 表 / v2 message.data.content 提取后归一化）。
public struct OpenCodeToolCall: Sendable, Equatable {
    public let id: String
    /// 工具名：v1 `tool` / v2 `name`。
    public let name: String
    /// 工具调用时间（epoch 毫秒）：v1 part.time_created / v2 tool.time.created（缺失回退 message.time_created）。
    public let timeCreatedMillis: Int64
    /// 状态：completed/error/running/streaming 等（原样小写）。
    public let status: String?
    /// 耗时（毫秒）：v1 state.time.{start,end} / v2 time.{ran,completed}（ran 缺失则 created→completed）。
    public let durationMs: Double?
    /// state.input.name（skill 名，仅 skill 工具调用有值）。
    public let inputName: String?
}

/// message 查询条件（CostProvider 用增量 sinceMillis，NodeStats 用 dataLike 预过滤）。
public struct OpenCodeMessageQuery: Sendable {
    public var sinceMillis: Int64?
    public var dataLike: String?

    public init(sinceMillis: Int64? = nil, dataLike: String? = nil) {
        self.sinceMillis = sinceMillis
        self.dataLike = dataLike
    }
}

// MARK: - 协议

public protocol OpenCodeStorage: Sendable {
    var schema: OpenCodeSchema { get }

    /// 读 assistant 消息。dbPath 为快照 db 路径，调用方负责 resolve + 快照生命周期。
    func fetchMessages(dbPath: String, query: OpenCodeMessageQuery) throws -> [OpenCodeMessage]

    /// 读工具调用。dbPath 为快照 db 路径。
    func fetchToolCalls(dbPath: String, sinceMillis: Int64?) throws -> [OpenCodeToolCall]

    /// 读全部凭据（providerID → key）。
    func loadAllCredentials() -> [String: String]

    /// 写入/覆盖单个凭据；失败返回 false（调用方回退内联 key）。
    @discardableResult
    func upsertCredential(providerID: String, key: String) -> Bool

    /// 删除单个凭据；失败返回 false。
    @discardableResult
    func deleteCredential(providerID: String) -> Bool

    /// 参与配置文件事务的凭据路径（v1 为 auth.json；v2 凭据在 opencode.db 内，返回空）。
    var credentialFilePaths: [String] { get }
}

// MARK: - 路由

/// 按本机 opencode 版本返回对应 reader。探测失败回退 v1（唯一正式版）。
public func resolveOpenCodeStorage(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> OpenCodeStorage {
    switch detectOpenCodeSchema() {
    case .v2:
        return OpenCodeV2Storage(homeDirectory: homeDirectory, environment: environment)
    case .v1:
        return OpenCodeV1Storage(homeDirectory: homeDirectory, environment: environment)
    }
}

/// 解析 opencode 数据目录（版本无关，供 credential 读写用）。
/// 返回第一个已存在的目录；都不存在返回默认（~/.local/share/opencode），写时 createDirectory 兜底。
func resolveOpenCodeDataDirectory(homeDirectory: String, environment: [String: String]) -> String {
    var candidates: [String] = []
    if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
        candidates.append((xdg as NSString).appendingPathComponent("opencode"))
    }
    candidates.append((homeDirectory as NSString).appendingPathComponent(".local/share/opencode"))
    candidates.append((homeDirectory as NSString).appendingPathComponent("Library/Application Support/opencode"))
    return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? candidates[1]
}

// MARK: - SQLite 绑定 helper

enum BindValue {
    case int64(Int64)
    case text(String)
}

func bind(_ values: [BindValue], to statement: OpaquePointer?) {
    guard let statement else { return }
    for (index, value) in values.enumerated() {
        let position = Int32(index + 1)
        switch value {
        case .int64(let int):
            sqlite3_bind_int64(statement, position, int)
        case .text(let str):
            sqlite3_bind_text(statement, position, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
