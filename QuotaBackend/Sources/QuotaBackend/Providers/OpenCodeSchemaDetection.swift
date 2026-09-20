import Foundation

// MARK: - OpenCode Schema Detection
// 探测 opencode 是 v1 还是 v2，决定用量/节点/调用分析走哪套读取路径。
// 依据：OpenCode 1 和 2 都用 `opencode` 命令且默认不共存（v2 安装替换 v1 二进制，
// 见官方 migrate-v1 文档），故 `opencode --version` 的主版本号是唯一权威的版本信号：
//   1.x → v1（`message` 表 + data JSON 顶层 providerID/modelID + 独立 `part` 表）
//   2.x → v2（`session_message` 表 + data JSON 嵌套 model 对象 + tool 调用在 data.content 内）
// 探测失败（opencode 未安装/不在 PATH/执行失败）回退 v1——v1 是当前唯一正式版。

public enum OpenCodeSchema: Sendable, Equatable {
    case v1
    case v2
}

func detectOpenCodeSchema() -> OpenCodeSchema {
    guard let version = opencodeVersion() else { return .v1 }
    return isV2(version) ? .v2 : .v1
}

/// 执行 `opencode --version` 拿版本号；失败返回 nil。
private func opencodeVersion() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["opencode", "--version"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        guard let pipe = process.standardOutput as? Pipe,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

/// 主版本号 >= 2 → v2；否则 v1。兼容 "opencode v2.0.11" / "2.0.11" / "v2.0.11" 等输出。
private func isV2(_ version: String) -> Bool {
    // 提取第一个连续数字序列作为主版本号（跳过命令名前缀与 v 前缀）。
    var digits = ""
    for char in version {
        if char.isNumber {
            digits.append(char)
        } else if !digits.isEmpty {
            break
        }
    }
    return (Int(digits) ?? 0) >= 2
}
