import Foundation

// MARK: - Global Config
// A shared settings.json fragment stored at ~/.config/aiusage/global-config.json.
// When enabled, its settings are deep-merged (as base) with the activated node's
// settings (as override) before writing to ~/.claude/settings.json.
// Node-specific values always take priority over global config.

struct GlobalConfig {
    var enabled: Bool
    var settings: [String: Any]

    init(enabled: Bool, settings: [String: Any]) {
        self.enabled = enabled
        self.settings = settings
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
        let root: [String: Any] = [
            "enabled": enabled,
            "settings": settings,
        ]
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
        return GlobalConfig(enabled: enabled, settings: settings)
    }
}
