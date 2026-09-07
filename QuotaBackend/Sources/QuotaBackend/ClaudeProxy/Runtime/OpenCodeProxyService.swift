import Foundation

// MARK: - OpenCode Proxy Service
// 入站: OpenAI chat/completions 请求 → 忠实透传 → OpenAI 兼容上游 → 原样回传。
// 不改写请求体（包括 model 字段），仅附加上游鉴权与少量入站头；
// 旁路解析 usage 用于请求日志展示（不参与计费，计费以 opencode.db 为准）。
// 错误结构复用 CodexErrorResponse（即 OpenAI 风格 {"error":{...}}，与 Codex 入站共用同一形状）。

public actor OpenCodeProxyService {
    private let configuration: OpenCodeProxyConfiguration
    private let upstreamClient: OpenAICompatibleClient

    public init(configuration: OpenCodeProxyConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        self.upstreamClient = OpenAICompatibleClient(
            configuration: configuration.makeUpstreamClientConfiguration()
        )
    }

    // MARK: - Authentication

    public func authenticate(headers: [String: String]) -> Bool {
        guard let expectedKey = configuration.expectedClientAPIKey else {
            return true
        }
        if let apiKey = headers["x-api-key"], apiKey == expectedKey {
            return true
        }
        if let auth = headers["authorization"] {
            let bearer = "Bearer "
            if auth.hasPrefix(bearer) {
                let token = String(auth.dropFirst(bearer.count))
                if token == expectedKey {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Faithful Passthrough (chat/completions → chat/completions)

    public struct PassthroughUsage: Sendable {
        /// Non-cached prompt tokens. OpenAI 把缓存命中计入 `prompt_tokens`，
        /// 这里先扣除 `prompt_tokens_details.cached_tokens` 再写入日志。
        public let inputTokens: Int
        public let outputTokens: Int
        public let cachedTokens: Int
    }

    public struct PassthroughResult: Sendable {
        public let statusCode: Int
        public let data: Data
        public let requestID: String?
        public let usage: PassthroughUsage?
    }

    /// 非流式透传。
    public func passthroughChatCompletions(
        rawBody: Data,
        inboundHeaders: [String: String]
    ) async throws -> PassthroughResult {
        let result = try await upstreamClient.sendRaw(
            path: "/chat/completions",
            bodyJSON: rawBody,
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders)
        )
        let usage = (200..<300).contains(result.statusCode)
            ? Self.parseUsage(fromResponseBody: result.data)
            : nil
        return PassthroughResult(
            statusCode: result.statusCode,
            data: result.data,
            requestID: result.requestID,
            usage: usage
        )
    }

    /// 全局代理只发布固定虚拟模型；普通节点代理仍忠实透传上游目录。
    public func passthroughModels(inboundHeaders: [String: String]) async throws -> RawResponsesResult {
        if let model = configuration.publicModel {
            let data = try JSONSerialization.data(withJSONObject: [
                "object": "list",
                "data": [[
                    "id": model,
                    "object": "model",
                    "created": 0,
                    "owned_by": "aiusage",
                ]],
            ])
            return RawResponsesResult(statusCode: 200, data: data, requestID: nil)
        }
        return try await upstreamClient.fetchRawModels(
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders)
        )
    }

    /// 流式透传：逐 data 帧把上游 SSE 原样回调给入站层（含末尾 `[DONE]`）。
    public func passthroughStreamingChatCompletions(
        rawBody: Data,
        inboundHeaders: [String: String],
        onData: @escaping (_ data: String) async throws -> Void
    ) async throws {
        try await upstreamClient.streamRawChatCompletions(
            bodyJSON: rawBody,
            extraHeaders: Self.forwardableHeaders(from: inboundHeaders),
            onData: onData
        )
    }

    /// 转发入站关键头（鉴权由 makeUpstreamRequest 注入，剔除会冲突的头）。
    private static func forwardableHeaders(from inbound: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        if let userAgent = inbound["user-agent"], !userAgent.isEmpty {
            out["User-Agent"] = userAgent
        }
        return out
    }

    // MARK: - Usage Parsing

    /// 解析非流式响应体顶层 usage（chat.completion 对象）。
    static func parseUsage(fromResponseBody data: Data) -> PassthroughUsage? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        return makeUsage(usage)
    }

    /// 从流式帧的 data 文本中解析 usage。
    /// 注意: 部分上游每个 chunk 都带 `"usage": null`，仅最后一帧（stream_options.include_usage）
    /// 才是对象，故 usage 非字典时返回 nil。
    public static func parseUsage(fromStreamFrame frameData: String) -> PassthroughUsage? {
        guard let data = frameData.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let usage = object["usage"] as? [String: Any] else {
            return nil
        }
        return makeUsage(usage)
    }

    private static func makeUsage(_ usage: [String: Any]) -> PassthroughUsage {
        let rawPrompt = max(0, intValue(usage["prompt_tokens"]))
        let output = max(0, intValue(usage["completion_tokens"]))
        var cached = 0
        if let details = usage["prompt_tokens_details"] as? [String: Any] {
            cached = min(rawPrompt, max(0, intValue(details["cached_tokens"])))
        }
        let input = rawPrompt - cached
        return PassthroughUsage(inputTokens: input, outputTokens: output, cachedTokens: cached)
    }

    private static func intValue(_ any: Any?) -> Int {
        if let n = any as? Int { return n }
        if let n = any as? Double { return Int(n) }
        if let n = any as? NSNumber { return n.intValue }
        return 0
    }

    // MARK: - Error Handling

    public func buildErrorResult(error: Error) -> CodexProxyErrorResult {
        let errorType: String
        let errorMessage: String
        let statusCode: Int
        var requestID: String?

        switch error {
        case let configError as ConfigurationError:
            errorType = "invalid_request_error"
            errorMessage = configError.localizedDescription
            statusCode = 400

        case let upstreamError as UpstreamError:
            switch upstreamError {
            case .httpError(let upstreamStatusCode, let upstreamMessage, let upstreamRequestID):
                errorType = Self.openAIErrorType(forHTTPStatus: upstreamStatusCode)
                errorMessage = Self.upstreamErrorMessage(from: upstreamMessage, statusCode: upstreamStatusCode)
                statusCode = upstreamStatusCode
                requestID = upstreamRequestID
            case .invalidURL(let url):
                errorType = "api_error"
                errorMessage = "Invalid upstream URL: \(url)"
                statusCode = 500
            case .invalidResponse(let message):
                errorType = "api_error"
                errorMessage = "Invalid response: \(message)"
                statusCode = 500
            case .decodingFailed(let message):
                errorType = "api_error"
                errorMessage = "Decoding failed: \(message)"
                statusCode = 500
            case .streamingFailed(let message):
                errorType = "api_error"
                errorMessage = "Streaming failed: \(message)"
                statusCode = 500
            }

        default:
            errorType = "api_error"
            errorMessage = error.localizedDescription
            statusCode = 500
        }

        return CodexProxyErrorResult(
            response: CodexErrorResponse(
                error: CodexErrorResponse.Body(message: errorMessage, type: errorType),
                requestID: requestID
            ),
            statusCode: statusCode
        )
    }

    private static func openAIErrorType(forHTTPStatus statusCode: Int) -> String {
        switch statusCode {
        case 400:
            return "invalid_request_error"
        case 401:
            return "authentication_error"
        case 403:
            return "permission_error"
        case 404:
            return "not_found_error"
        case 429:
            return "rate_limit_error"
        case 400..<500:
            return "invalid_request_error"
        default:
            return "api_error"
        }
    }

    private static func upstreamErrorMessage(from rawMessage: String, statusCode: Int) -> String {
        if let data = rawMessage.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errorObject = object["error"] as? [String: Any],
               let message = errorObject["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
            if let message = object["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return message
            }
        }
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return "Upstream request failed with HTTP \(statusCode)."
    }
}
