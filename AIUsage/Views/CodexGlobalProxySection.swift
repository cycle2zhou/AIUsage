import SwiftUI

// MARK: - Codex Global Proxy Section
// Codex 轨「全局统一代理」配置卡片：常驻固定端口对外只暴露一个可编辑客户端模型名，
// Codex CLI 一次性指向它即可。切换激活节点走进程内热替换，CLI 无感（无需重启 / 端口不变）。
// 节点与真实模型都在本卡片直接热切换；思考程度继续由 Codex 客户端控制。

struct CodexGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.shared
    @ObservedObject private var runtime = GlobalProxyRuntime.codex
    @ObservedObject private var proxyVM = ProxyViewModel.shared

    @State private var selectedNodeId: String = ""

    private static let codexBrand = Color(red: 0.40, green: 0.52, blue: 0.92)

    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.codexBrand,
            title: L("Global Proxy", "全局代理"),
            subtitle: L("One stable endpoint; hot-switch nodes and models here.", "一个固定入口，可在这里热切换节点与模型。"),
            isEnabled: isEnabled,
            isRunning: runtime.isRunning,
            isRuntimeOwnedByAnotherConsumer: false,
            otherConsumerStatus: nil,
            isBusy: manager.isBusy,
            port: manager.config.port,
            bindHost: manager.config.displayBindHost,
            allowLAN: allowLANBinding,
            hasNodes: !nodes.isEmpty,
            showsDedicatedRoute: true,
            emptyHint: L("Create a Codex node first to use the global proxy.", "请先创建 Codex 节点后再使用全局代理。"),
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
    }

    // MARK: - Live Route (node → real model)

    private var nodeControl: some View {
        HStack(spacing: 8) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.codexBrand,
                title: currentNodeName,
                systemImage: "bolt.fill",
                isDisabled: manager.isBusy,
                items: nodes.map { GlobalProxyPickerItem(id: $0.id, name: $0.name) },
                selectedId: nodeBinding.wrappedValue,
                onSelect: { nodeBinding.wrappedValue = $0 }
            )
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            GlobalProxyInlineLabel(text: L("Real Model", "真实模型"))
            GlobalProxyChipMenu(
                brand: Self.codexBrand,
                title: currentModelName,
                systemImage: "cpu",
                isDisabled: manager.isBusy || routeNodeId.isEmpty,
                items: routeModels.map { GlobalProxyPickerItem(id: $0, name: $0) },
                selectedId: currentModelName,
                onSelect: { modelBinding.wrappedValue = $0 },
                emptyMessage: L("No models available", "暂无可用模型")
            )
            Spacer(minLength: 0)
        }
    }

    private var currentNodeName: String {
        let id = nodeBinding.wrappedValue
        return nodes.first(where: { $0.id == id })?.name ?? L("Select", "选择")
    }

    private var routeNodeId: String { nodeBinding.wrappedValue }
    private var routeModels: [String] { manager.availableModels(for: routeNodeId) }
    private var currentModelName: String {
        manager.routedModel(for: routeNodeId) ?? L("Select", "选择")
    }

    // MARK: - Running Summary (read-only chips when enabled)

    @ViewBuilder private var runningSummary: some View {
        GlobalProxySummaryChip(
            label: L("Client Model", "客户端模型"),
            value: manager.config.virtualModel.nilIfBlank ?? GlobalProxyConfig.defaultClientModel
        )
        if let model = manager.routedModel(for: routeNodeId) {
            GlobalProxySummaryChip(label: L("Routes To", "路由到"), value: model)
        }
    }

    // MARK: - Configuration (connection only; editable while disabled)

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                GlobalProxyField(label: L("Client Model", "客户端模型")) {
                    TextField("LLM", text: clientModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .help(L(
                            "The only model name shown in Codex.",
                            "Codex 中显示的唯一模型名称。"
                        ))
                }
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField(
                        "14399",
                        value: portBinding,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Spacer(minLength: 0)
            }
            GlobalProxyRestartNotice(text: L(
                "After changing the client model, turn the global proxy back on and restart Codex. Real-model switching remains live, and reasoning effort stays in Codex.",
                "修改客户端模型名后，请重新启用全局代理并重启 Codex；真实模型仍可热切换，思考程度仍由 Codex 控制。"
            ))
        }
    }

    private var allowLANBinding: Binding<Bool> {
        Binding(
            get: { manager.config.effectiveAllowLAN },
            set: { manager.updateAllowLAN($0) }
        )
    }

    private var portBinding: Binding<Int> {
        Binding(
            get: { manager.config.port },
            set: {
                manager.updateSettings(
                    port: $0,
                    virtualModel: manager.config.virtualModel,
                    clientKey: manager.config.clientKey
                )
            }
        )
    }

    private var clientModelBinding: Binding<String> {
        Binding(
            get: { manager.config.virtualModel },
            set: {
                manager.updateSettings(
                    port: manager.config.port,
                    virtualModel: $0,
                    clientKey: manager.config.clientKey
                )
            }
        )
    }

    private var enableBinding: Binding<Bool> {
        Binding(
            get: { isEnabled },
            set: { newValue in
                if newValue {
                    let target = resolvedSelection
                    guard !target.isEmpty else { return }
                    Task { await manager.enable(activeNodeId: target) }
                } else {
                    Task { await manager.disable() }
                }
            }
        )
    }

    private var nodeBinding: Binding<String> {
        Binding(
            get: { isEnabled ? (manager.activeNodeId ?? resolvedSelection) : resolvedSelection },
            set: { newId in
                selectedNodeId = newId
                if isEnabled {
                    Task { await manager.switchActiveNode(to: newId) }
                }
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { currentModelName },
            set: { newModel in
                let nodeId = routeNodeId
                guard !nodeId.isEmpty else { return }
                Task { await manager.switchRoutedModel(to: newModel, for: nodeId) }
            }
        )
    }

    // MARK: - Helpers

    /// 当前选定节点（兜底到首个可用节点），保证 Picker/启用按钮总有合法目标。
    private var resolvedSelection: String {
        if !selectedNodeId.isEmpty, nodes.contains(where: { $0.id == selectedNodeId }) {
            return selectedNodeId
        }
        return manager.activeNodeId ?? nodes.first?.id ?? ""
    }

    private func syncFromConfig() {
        selectedNodeId = resolvedSelection
    }
}
