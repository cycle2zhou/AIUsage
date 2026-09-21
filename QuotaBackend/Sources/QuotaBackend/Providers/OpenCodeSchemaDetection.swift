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

/// 执行 `opencode --version` 拿版本号；三层探测，失败返回 nil。
/// GUI App 从 Finder/Dock 启动时进程 PATH 是 launchd 的最小值（不含 Homebrew 等用户路径），
/// 仅靠 `/usr/bin/env opencode` 会找不到二进制导致误判 v1。故分层兜底：
///   1. 当前进程 PATH（Xcode/终端场景最快命中）
///   2. login shell 动态解析 `command -v opencode`（覆盖 PATH 持久化在 shell 配置里的标准用户）
///   3. 固定安装路径枚举（覆盖终端模拟器/mise 运行时注入 PATH、未落盘的边缘环境）
private func opencodeVersion() -> String? {
    // 1. 当前进程 PATH。
    if let version = runOpenCodeVersion(executable: "/usr/bin/env", arguments: ["opencode", "--version"]) {
        return version
    }
    // 2. login shell 动态解析（标准 Homebrew 用户把 PATH 写在 ~/.zprofile，login shell 能加载到）。
    if let path = resolveCommandPathViaLoginShell("opencode"),
       let version = runOpenCodeVersion(executable: path, arguments: ["--version"]) {
        return version
    }
    // 3. 固定路径枚举兜底（覆盖 PATH 未持久化到任何 shell 配置的环境）。
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/opt/homebrew/bin/opencode",
        "/usr/local/bin/opencode",
        (home as NSString).appendingPathComponent(".opencode/bin/opencode"),
        (home as NSString).appendingPathComponent(".local/bin/opencode"),
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        if let version = runOpenCodeVersion(executable: path, arguments: ["--version"]) {
            return version
        }
    }
    return nil
}

/// 以指定可执行文件跑 `opencode --version`，成功返回裁剪后的版本串，否则 nil。
private func runOpenCodeVersion(executable: String, arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
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

/// 用 login shell（非交互式 `zsh -l -c`）解析命令的绝对路径；找不到或非绝对路径返回 nil。
/// 不解析成功时不会抛错——调用方按需降级到固定路径枚举。
private func resolveCommandPathViaLoginShell(_ command: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-l", "-c", "command -v \(command)"]
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
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? path : nil
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
