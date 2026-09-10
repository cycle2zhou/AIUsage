import SwiftUI

// MARK: - OpenCode Default Model Node Section
// 「默认模型节点」独立卡片（与通用配置解耦）：多节点同时激活时，顶层 model 指向
// 显式选择的节点；未选择（Auto）时回退到第一个激活节点；全部停用时由父视图隐藏。

struct OpenCodeDefaultModelNodeSection: View {
    @ObservedObject var store: OpenCodeNodeStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "star.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Default model node", "默认模型节点"))
                    .font(.subheadline.weight(.semibold))
                Text(L("Top-level model follows the selected active node", "顶层模型跟随所选激活节点"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: Binding<String?>(
                get: { store.openCodeDefaultNodeId },
                set: { store.setOpenCodeDefaultNodeId($0) }
            )) {
                Text(L("Auto (first active node)", "自动（第一个激活节点）"))
                    .tag(nil as String?)
                ForEach(store.activeNodes, id: \.id) { node in
                    Text(node.displayName).tag(node.id as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }
}
