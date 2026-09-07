import SwiftUI

/// 可复用的 per-model key-value 参数编辑器（issue #69）。
/// 编辑 `[String: String]` 形式的任意追加参数，供 OpenCode 节点模型行与
/// 统一 API Provider 模型库两处复用；值存字符串，生成时由配置管理器智能解析。
struct ModelExtraParametersEditor: View {
    @Binding var parameters: [String: String]
    @State private var rows: [Row] = []

    private struct Row: Identifiable, Equatable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rows) { $row in
                HStack(spacing: 6) {
                    TextField(L("key", "键"), text: $row.key)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .autocorrectionDisabled()
                    TextField(L("value", "值"), text: $row.value)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .autocorrectionDisabled()
                    Button {
                        rows.removeAll { $0.id == $row.wrappedValue.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .frame(width: 20)
                    .help(L("Remove parameter", "移除参数"))
                }
            }
            Button {
                rows.append(Row())
            } label: {
                Label(L("Add parameter", "添加参数"), systemImage: "plus.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .onAppear { loadIfNeeded() }
        .onChange(of: rows) { _, _ in persist() }
    }

    private func loadIfNeeded() {
        guard rows.isEmpty else { return }
        rows = parameters
            .map { Row(key: $0.key, value: $0.value) }
            .sorted { $0.key < $1.key }
    }

    private func persist() {
        var next: [String: String] = [:]
        for row in rows {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { next[key] = row.value }
        }
        if next != parameters { parameters = next }
    }
}
