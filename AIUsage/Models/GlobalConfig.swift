import Foundation

// MARK: - Global Config
// A shared settings.json fragment stored at ~/.config/aiusage/global-config.json.
// When enabled, its settings are deep-merged (as base) with the activated node's
// settings (as override) before writing to ~/.claude/settings.json.
// Node-specific values always take priority over global config.

struct GlobalConfig {
    var enabled: Bool
    var settings: [String: Any]
    /// OpenCode 代理「通用配置」中显式选择的默认节点（顶层 model 指向它）。
    /// nil 表示未显式选择，重写受管配置时回退到第一个激活节点。
    var openCodeDefaultNodeId: String?

    init(enabled: Bool, settings: [String: Any], openCodeDefaultNodeId: String? = nil) {
        self.enabled = enabled
        self.settings = settings
        self.openCodeDefaultNodeId = openCodeDefaultNodeId
    }

    static let empty = GlobalConfig(enabled: false, settings: [:])

    // MARK: - Deep Merge

    /// Recursively merges two dictionaries. Values in `override` take priority.
    /// Nested dictionaries are merged recursively rather than replaced wholesale.
    static func deepMerge(
        base: [String: Any],
        override: [String: Any]
    ) -> [String: Any] {
        var result = base
        for (key, overrideValue) in override {
            if let baseDict = result[key] as? [String: Any],
               let overrideDict = overrideValue as? [String: Any] {
                result[key] = deepMerge(base: baseDict, override: overrideDict)
            } else {
                result[key] = overrideValue
            }
        }
        return result
    }

    // MARK: - Serialize / Deserialize

    func toFileData() throws -> Data {
        var root: [String: Any] = [
            "enabled": enabled,
            "settings": settings,
        ]
        if let nodeId = openCodeDefaultNodeId {
            root["openCodeDefaultNodeId"] = nodeId
        }
        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func fromFileData(_ data: Data) throws -> GlobalConfig {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let enabled = root["enabled"] as? Bool ?? false
        let settings = root["settings"] as? [String: Any] ?? [:]
        let openCodeDefaultNodeId = root["openCodeDefaultNodeId"] as? String
        return GlobalConfig(enabled: enabled, settings: settings, openCodeDefaultNodeId: openCodeDefaultNodeId)
    }
}
