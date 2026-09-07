import Foundation

// MARK: - Codex Proxy Configuration
// Codex 代理把 OpenAI Responses 入站请求转换到「OpenAI 兼容上游」(Phase B)。
// 与 ClaudeProxyConfiguration 平行，但入站协议是 Responses，模型映射为单一覆盖。
//
// 进程模型: 每个 Codex 节点启动独立的 QuotaServer 进程，通过环境变量 PROXY_TARGET=codex 区分。

public struct CodexProxyConfiguration: Sendable {
    public let enabled: Bool
    /// TCP port this proxy configuration is intended to bind on (1–65535).
    public let bindPort: Int
    public let mode: ProxyMode
    public let upstreamBaseURL: String
    public let openAIUpstreamAPI: OpenAIUpstreamAPI
    public let upstreamAPIKey: String
    public let expectedClientKey: String?
    /// 上游模型覆盖；为空时透传 Codex 请求里的模型名。
    public let upstreamModel: String?
    /// 对客户端发布的唯一模型名；仅全局代理设置，普通节点代理继续透传上游目录。
    public let publicModel: String?
    public let maxOutputTokens: Int?
    public let requestTimeout: TimeInterval
    public let customHeaders: [String: String]

    public init(
        enabled: Bool,
        bindPort: Int = 4319,
        mode: ProxyMode = .openaiConvert,
        upstreamBaseURL: String,
        openAIUpstreamAPI: OpenAIUpstreamAPI = .chatCompletions,
        upstreamAPIKey: String,
        expectedClientKey: String? = nil,
        upstreamModel: String? = nil,
        publicModel: String? = nil,
        maxOutputTokens: Int? = nil,
        requestTimeout: TimeInterval = 120,
        customHeaders: [String: String] = [:]
    ) {
        self.enabled = enabled
        self.bindPort = bindPort
        self.mode = mode
        self.upstreamBaseURL = mode == .openaiConvert
            ? ClaudeProxyConfiguration.normalizeOpenAIBaseURL(upstreamBaseURL)
            : upstreamBaseURL
        self.openAIUpstreamAPI = openAIUpstreamAPI
        self.upstreamAPIKey = upstreamAPIKey
        self.expectedClientKey = expectedClientKey
        self.upstreamModel = upstreamModel?.nilIfBlank
        self.publicModel = publicModel?.nilIfBlank
        self.maxOutputTokens = maxOutputTokens
        self.requestTimeout = requestTimeout
        self.customHeaders = customHeaders
    }

    public var expectedClientAPIKey: String? { expectedClientKey }

    /// 把入站模型映射到上游模型：配置了覆盖则用覆盖，否则透传。
    public func mapToUpstreamModel(_ requestModel: String) -> String {
        upstreamModel ?? requestModel
    }

    public func validate() throws {
        if upstreamAPIKey.isEmpty {
            throw ConfigurationError.missingAPIKey
        }
        if upstreamBaseURL.isEmpty {
            throw ConfigurationError.invalidURL
        }
        guard (1...65_535).contains(bindPort) else {
            throw ConfigurationError.invalidPort
        }
    }

    /// 复用 OpenAICompatibleClient（它接受 ClaudeProxyConfiguration），把本配置投影为上游客户端配置。
    /// 注意: 这里的 ClaudeProxyConfiguration 实际充当「OpenAI 上游配置」，与 Claude 入站无关（技术债，见 docs）。
    public func makeUpstreamClientConfiguration() -> ClaudeProxyConfiguration {
        ClaudeProxyConfiguration(
            enabled: enabled,
            bindPort: bindPort,
            mode: .openaiConvert,
            upstreamBaseURL: upstreamBaseURL,
            openAIUpstreamAPI: openAIUpstreamAPI,
            upstreamAPIKey: upstreamAPIKey,
            expectedClientKey: expectedClientKey,
            maxOutputTokens: maxOutputTokens,
            requestTimeout: requestTimeout,
            customHeaders: customHeaders
        )
    }

    public static func loadFromEnvironment() -> CodexProxyConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PROXY_TARGET"]?.lowercased() == "codex" else {
            return nil
        }
        guard let apiKey = environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
            return nil
        }

        let baseURL = environment["OPENAI_BASE_URL"] ?? "https://api.openai.com"
        let upstreamAPI = OpenAIUpstreamAPI.fromEnvironment(environment["OPENAI_API_MODE"])
        let clientKey = environment["CODEX_CLIENT_KEY"]?.nilIfBlank
        let upstreamModel = environment["CODEX_UPSTREAM_MODEL"]?.nilIfBlank
        let publicModel = environment["CODEX_PUBLIC_MODEL"]?.nilIfBlank
        let maxOutputTokens = environment["MAX_OUTPUT_TOKENS"].flatMap { Int($0) }

        return CodexProxyConfiguration(
            enabled: true,
            mode: .openaiConvert,
            upstreamBaseURL: baseURL,
            openAIUpstreamAPI: upstreamAPI,
            upstreamAPIKey: apiKey,
            expectedClientKey: clientKey,
            upstreamModel: upstreamModel,
            publicModel: publicModel,
            maxOutputTokens: maxOutputTokens
        )
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
