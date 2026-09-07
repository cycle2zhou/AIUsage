import SwiftUI
import QuotaBackend

// MARK: - OpenCode Global Proxy Section
// OpenCode 轨「全局统一代理」配置卡片：常驻固定端口对外只暴露一个可编辑客户端模型名，
// opencode.json 一次性指向它即可（受管 provider 块 + 顶层 model）。启用时先选定接口协议
// （OpenAI 兼容 / Anthropic / OpenAI Responses），只能在「同接口」节点间热切换以保证 wire 格式兼容；
// 节点与真实模型都在本卡片直接热切换（改写 model），CLI 无感、端口不变。
// 启用期间接管 opencode.json，并禁用每节点单独激活（由本卡片统一切换激活节点）。
// 成本/用量走代理日志按节点定价归因（不依赖 opencode.db），与 Claude/Codex 全局代理同口径。

struct OpenCodeGlobalProxySection: View {
    @ObservedObject private var manager = GlobalProxyManager.opencode
    @ObservedObject private var runtime = GlobalProxyRuntime.opencode
    @ObservedObject private var store = OpenCodeNodeStore.shared

    @State private var selectedNodeId: String = ""

    private static let brand = Color(red: 0.18, green: 0.83, blue: 0.75)

    private var interface: OpenCodeProtocol { manager.config.effectiveOpenCodeInterface }
    private var nodes: [GlobalProxyNodeRef] { manager.availableNodes() }
    private var isEnabled: Bool { manager.isEnabled }

    var body: some View {
        GlobalProxySectionScaffold(
            brand: Self.brand,
            title: L("Global Proxy", "全局代理"),
            subtitle: L("One stable endpoint; hot-switch nodes and models within the selected interface.", "一个固定入口，可在同接口下热切换节点与模型。"),
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
            emptyHint: emptyHint,
            errorText: manager.operationError,
            toggle: enableBinding,
            nodeControl: { nodeControl },
            config: { configContent },
            runningSummary: { runningSummary }
        )
        .onAppear(perform: syncFromConfig)
        // 节点列表/接口变化后，保证选择项仍有效。
        .onChange(of: store.nodes.count) { _, _ in selectedNodeId = resolvedSelection }
    }

    // MARK: - Live Route (node → real model)

    private var nodeControl: some View {
        HStack(spacing: 8) {
            GlobalProxyInlineLabel(text: L("Active Node", "激活节点"))
            GlobalProxyChipMenu(
                brand: Self.brand,
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
                brand: Self.brand,
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
        GlobalProxySummaryChip(label: L("Interface", "接口"), value: interface.displayName)
        GlobalProxySummaryChip(
            label: L("Client Model", "客户端模型"),
            value: manager.config.virtualModel.nilIfBlank ?? GlobalProxyConfig.defaultClientModel
        )
        if let model = manager.routedModel(for: routeNodeId) {
            GlobalProxySummaryChip(label: L("Routes To", "路由到"), value: model)
        }
    }

    // MARK: - Configuration (interface + connection)
    // 接口决定 npm 包 / 后端透传轨道 / 可切换的节点集合；启用后锁定（换接口需先停用），故归入折叠配置区。

    private var configContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                GlobalProxyField(label: L("Interface", "接口")) {
                    GlobalProxyChipMenu(
                        brand: Self.brand,
                        title: interface.displayName,
                        systemImage: "arrow.left.arrow.right",
                        isDisabled: isEnabled || manager.isBusy,
                        items: OpenCodeProtocol.allCases.map {
                            GlobalProxyPickerItem(id: $0.rawValue, name: $0.displayName)
                        },
                        selectedId: interface.rawValue,
                        onSelect: { raw in
                            if let proto = OpenCodeProtocol(rawValue: raw) {
                                interfaceBinding.wrappedValue = proto
                            }
                        }
                    )
                }
                GlobalProxyField(label: L("Client Model", "客户端模型")) {
                    TextField("LLM", text: clientModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .help(L(
                            "The only model name shown in OpenCode.",
                            "OpenCode 中显示的唯一模型名称。"
                        ))
                }
                GlobalProxyField(label: L("Port", "端口")) {
                    TextField(
                        "14401",
                        value: portBinding,
                        format: IntegerFormatStyle<Int>.number.grouping(.never)
                    )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                }
                Spacer(minLength: 0)
            }
            GlobalProxyRestartNotice(text: L(
                "After changing the client model, turn the global proxy back on and restart OpenCode. Real-model switching remains live.",
                "修改客户端模型名后，请重新启用全局代理并重启 OpenCode；真实模型仍可热切换。"
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

    private var interfaceBinding: Binding<OpenCodeProtocol> {
        Binding(
            get: { interface },
            set: { newValue in
                manager.updateOpenCodeInterface(newValue)
                selectedNodeId = resolvedSelection
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

    private var emptyHint: String {
        L("No \(interface.displayName) node to use this interface. Create one, or pick another interface.",
          "没有可用于「\(interface.displayName)」接口的节点。请新建对应协议的节点，或切换其它接口。")
    }

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
