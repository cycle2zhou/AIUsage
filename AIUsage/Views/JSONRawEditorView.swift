import SwiftUI
import AppKit
import WebKit
import QuotaBackend

// MARK: - JSON Raw Editor View
// Full-screen code editor for raw JSON editing of settings.json content.
// Uses NSTextView via NSViewRepresentable with syntax highlighting for
// keys, string values, numbers, and booleans/null.

struct JSONRawEditorView: View {
    @Binding var jsonText: String
    @Binding var error: String?
    var title: String = L("settings.json", "settings.json")
    var isEditable: Bool = true
    var showsActions: Bool = true
    var isJSONC: Bool = false
    var lineMarkers: [Int: String] = [:]
    @State private var lineCount: Int = 1
    @State private var showValidationSuccess = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "curlybraces")
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L("\(lineCount) lines", "\(lineCount) 行"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if showsActions {
                    Button {
                        formatJSON()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "text.alignleft")
                            Text(L("Format", "格式化"))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)

                    Button {
                        validateJSON()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle")
                            Text(L("Validate", "校验"))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                }

                if showValidationSuccess {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(L("Valid JSON", "JSON 有效"))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            JSONTextEditor(
                text: $jsonText,
                lineCount: $lineCount,
                isEditable: isEditable,
                lineMarkers: lineMarkers
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let error {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }
        }
    }

    private func formatJSON() {
        showValidationSuccess = false
        if isJSONC {
            guard let formatted = JSONCEditor.format(jsonText) else {
                error = L("Cannot format: invalid JSONC", "无法格式化：JSONC 格式无效")
                return
            }
            jsonText = formatted
            error = nil
            return
        }
        guard let data = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let formatted = try? JSONSerialization.data(
                  withJSONObject: obj,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              ),
              let str = String(data: formatted, encoding: .utf8) else {
            error = L("Cannot format: invalid JSON", "无法格式化：JSON 格式无效")
            return
        }
        jsonText = str
        error = nil
    }

    private func validateJSON() {
        if isJSONC {
            if JSONCEditor.parseObject(jsonText) != nil {
                error = nil
                withAnimation(.easeInOut(duration: 0.25)) { showValidationSuccess = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation(.easeOut(duration: 0.3)) { showValidationSuccess = false }
                }
            } else {
                error = L("Root must be a valid JSONC object", "根节点必须是有效的 JSONC 对象")
                showValidationSuccess = false
            }
            return
        }
        guard let data = jsonText.data(using: .utf8) else {
            error = L("Invalid encoding", "编码无效")
            showValidationSuccess = false
            return
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard obj is [String: Any] else {
                error = L("Root must be a JSON object", "根节点必须是 JSON 对象")
                showValidationSuccess = false
                return
            }
            error = nil
            withAnimation(.easeInOut(duration: 0.25)) { showValidationSuccess = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut(duration: 0.3)) { showValidationSuccess = false }
            }
        } catch {
            self.error = error.localizedDescription
            showValidationSuccess = false
        }
    }
}

// MARK: - Web Code Editor

private struct JSONTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var lineCount: Int
    var isEditable: Bool
    var lineMarkers: [Int: String]

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "editor")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        webView.loadHTMLString(JSONWebEditorAssets.html, baseURL: nil)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyState()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: JSONTextEditor
        weak var webView: WKWebView?
        var isReady = false
        var lastAppliedText: String?
        var lastAppliedEditable: Bool?
        var lastAppliedMarkers: [Int: String] = [:]

        init(_ parent: JSONTextEditor) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            applyState(force: true)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let payload = message.body as? [String: Any],
                  let type = payload["type"] as? String else {
                return
            }
            switch type {
            case "textChanged":
                let nextText = payload["text"] as? String ?? ""
                parent.text = nextText
                parent.lineCount = payload["lineCount"] as? Int ?? nextText.components(separatedBy: "\n").count
                lastAppliedText = nextText
            case "lineCount":
                parent.lineCount = payload["lineCount"] as? Int ?? parent.lineCount
            default:
                break
            }
        }

        func applyState(force: Bool = false) {
            guard isReady, let webView else { return }
            guard force
                    || lastAppliedText != parent.text
                    || lastAppliedEditable != parent.isEditable
                    || lastAppliedMarkers != parent.lineMarkers else { return }
            lastAppliedText = parent.text
            lastAppliedEditable = parent.isEditable
            lastAppliedMarkers = parent.lineMarkers
            let textLiteral = Self.javascriptString(parent.text)
            let editableLiteral = parent.isEditable ? "true" : "false"
            let markersLiteral = Self.javascriptObject(parent.lineMarkers)
            webView.evaluateJavaScript("window.setEditorState(\(textLiteral), \(editableLiteral)); window.setLineMarkers(\(markersLiteral));")
        }

        private static func javascriptString(_ value: String) -> String {
            guard let data = try? JSONSerialization.data(withJSONObject: [value]),
                  let arrayLiteral = String(data: data, encoding: .utf8) else {
                return "''"
            }
            return "(\(arrayLiteral))[0]"
        }

        private static func javascriptObject(_ markers: [Int: String]) -> String {
            let keyed = Dictionary(uniqueKeysWithValues: markers.map { (String($0.key), $0.value) })
            guard let data = try? JSONSerialization.data(withJSONObject: keyed),
                  let objectLiteral = String(data: data, encoding: .utf8) else {
                return "{}"
            }
            return objectLiteral
        }
    }
}
