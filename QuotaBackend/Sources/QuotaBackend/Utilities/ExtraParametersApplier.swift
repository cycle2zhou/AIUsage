import Foundation

/// 每模型追加参数（issue #69）的纯解析/合并工具：把字符串值解析为 JSON 标量/对象/数组，
/// 再按点路径合并进模型 entry。从 AIUsage 侧抽到 QuotaBackend，便于 QuotaBackendTests 覆盖。
public enum ExtraParametersApplier {

    /// 把每模型追加参数按点路径合并进模型 entry，覆盖节点级默认（issue #69）。
    /// 值存字符串，此处智能解析为 JSON 标量/对象/数组后写入。
    public static func applyExtraParameters(
        _ parameters: [String: String],
        to entry: [String: Any]
    ) -> [String: Any] {
        var result = entry
        // 按 key 字典序排序：父子路径冲突（如 "limit" 与 "limit.context"）时父路径先写、
        // 子路径后写覆盖，结果确定，不依赖字典遍历顺序。
        for (key, rawValue) in parameters.sorted(by: { $0.key < $1.key }) {
            guard let value = parseParameterValue(rawValue) else { continue }
            setNestedValue(value, atPath: key, in: &result)
        }
        return result
    }

    /// 把字符串值解析为 JSON 值：整数/浮点/布尔/null 字面量、`{...}`/`[...]` 走 JSON 解析，
    /// 其余原样保留为字符串。
    public static func parseParameterValue(_ rawValue: String) -> Any? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let intValue = Int(trimmed) { return intValue }
        if let doubleValue = Double(trimmed), trimmed.contains(".") { return doubleValue }
        switch trimmed.lowercased() {
        case "true": return true
        case "false": return false
        case "null", "nil": return NSNull()
        default: break
        }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        return rawValue
    }

    /// 按点路径（如 "limit.context"）把值写入嵌套字典；多段 key 逐层创建中间字典。
    public static func setNestedValue(
        _ value: Any,
        atPath path: String,
        in dict: inout [String: Any]
    ) {
        let components = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard let first = components.first else { return }
        if components.count == 1 {
            dict[first] = value
            return
        }
        var child = dict[first] as? [String: Any] ?? [:]
        setNestedValue(value, atPath: components.dropFirst().joined(separator: "."), in: &child)
        dict[first] = child
    }
}
