import XCTest
@testable import QuotaBackend

final class JSONCEditorTests: XCTestCase {

    // MARK: - Helpers

    /// 朴素去注释后用 JSONSerialization 解析，验证产出文本仍是结构正确的 JSON。
    private func parse(_ jsonc: String) -> [String: Any]? {
        var result = ""
        var inString = false
        var escaped = false
        let chars = Array(jsonc)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                result.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            if c == "\"" { inString = true; result.append(c); i += 1; continue }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                i += 2; while i < chars.count, chars[i] != "\n" { i += 1 }; continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2; while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }; i += 2; continue
            }
            if c == "," {
                // 去尾随逗号（逗号后仅空白即遇 } 或 ]）
                var j = i + 1
                while j < chars.count, chars[j] == " " || chars[j] == "\t" || chars[j] == "\n" || chars[j] == "\r" { j += 1 }
                if j < chars.count, chars[j] == "}" || chars[j] == "]" { i += 1; continue }
            }
            result.append(c)
            i += 1
        }
        guard let data = result.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private func managedEntry(_ name: String, base: String) -> [String: Any] {
        [
            "npm": "@ai-sdk/openai-compatible",
            "name": name,
            "options": ["baseURL": base, "apiKey": "k"],
            "models": ["foo": ["name": "foo"]],
        ]
    }

    // MARK: - Comment Preservation

    func testInjectsManagedProviderKeepingComments() {
        let base = """
        {
          // 我的 OpenCode 配置
          "model": "openai/gpt-4",
          "provider": {
            // 自定义供应商
            "openrouter": {
              "npm": "@ai-sdk/openai-compatible"
            }
          }
        }
        """
        let target: [String: Any] = [
            "model": "aiusage-x/foo",
            "provider": [
                "openrouter": ["npm": "@ai-sdk/openai-compatible"],
                "aiusage-x": managedEntry("X", base: "https://api.x.com/v1"),
            ],
        ]

        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        let out = result!
        XCTAssertTrue(out.contains("// 我的 OpenCode 配置"), "顶层注释应保留")
        XCTAssertTrue(out.contains("// 自定义供应商"), "provider 内注释应保留")
        XCTAssertTrue(out.contains("\"openrouter\""), "用户原有 provider 应保留")
        XCTAssertTrue(out.contains("\"aiusage-x\""), "受管 provider 应注入")
        XCTAssertTrue(out.contains("\"model\": \"aiusage-x/foo\""), "顶层 model 应被替换")
        XCTAssertEqualJSON(parse(out), target)
    }

    func testAddsProviderAndSchemaWhenAbsentKeepingComments() {
        let base = """
        {
          // 只放了一个主题
          "theme": "dark"
        }
        """
        let target: [String: Any] = [
            "theme": "dark",
            "$schema": "https://opencode.ai/config.json",
            "model": "aiusage-x/foo",
            "provider": ["aiusage-x": managedEntry("X", base: "https://api.x.com/v1")],
        ]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        let out = result!
        XCTAssertTrue(out.contains("// 只放了一个主题"))
        XCTAssertTrue(out.contains("\"theme\": \"dark\""))
        XCTAssertTrue(out.contains("\"$schema\""))
        XCTAssertTrue(out.contains("\"aiusage-x\""))
        XCTAssertEqualJSON(parse(out), target)
    }

    func testInjectsIntoEmptyProviderObjectKeepingComment() {
        let base = """
        {
          // c
          "provider": {}
        }
        """
        let target: [String: Any] = [
            "provider": ["aiusage-x": managedEntry("X", base: "https://api.x.com/v1")],
        ]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("// c"))
        XCTAssertTrue(result!.contains("\"aiusage-x\""))
        XCTAssertEqualJSON(parse(result!), target)
    }

    // MARK: - Trailing Commas / Replacement

    func testToleratesTrailingCommaAndInserts() {
        let base = """
        {
          "a": 1,
        }
        """
        let target: [String: Any] = ["a": 1, "b": 2]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("\"b\": 2"))
        XCTAssertEqualJSON(parse(result!), target)
    }

    func testReplacesValueKeepingInlineComment() {
        let base = """
        {
          "a": 1, // keep me
          "b": 2
        }
        """
        let target: [String: Any] = ["a": 1, "b": 3]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("// keep me"), "未变更键的行内注释应保留")
        XCTAssertTrue(result!.contains("\"b\": 3"))
        XCTAssertEqualJSON(parse(result!), target)
    }

    func testDeepMergeOverrideChangesNestedValue() {
        let base = """
        {
          // 注释
          "agent": {
            "model": "old",
            "note": "keep"
          }
        }
        """
        let target: [String: Any] = [
            "agent": ["model": "new", "note": "keep"],
        ]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("// 注释"))
        XCTAssertTrue(result!.contains("\"model\": \"new\""))
        XCTAssertEqualJSON(parse(result!), target)
    }

    // MARK: - Deletion of stale managed keys

    func testRemovesStaleManagedKey() {
        let base = """
        {
          "provider": {
            "aiusage-old": { "npm": "x" },
            "mine": { "npm": "y" }
          },
          "model": "aiusage-old/m"
        }
        """
        let target: [String: Any] = [
            "provider": [
                "mine": ["npm": "y"],
                "aiusage-new": managedEntry("New", base: "https://n/v1"),
            ],
            "model": "aiusage-new/m",
        ]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        let out = result!
        XCTAssertFalse(out.contains("aiusage-old"), "陈旧受管键应被移除")
        XCTAssertTrue(out.contains("aiusage-new"))
        XCTAssertTrue(out.contains("\"mine\""))
        XCTAssertEqualJSON(parse(out), target)
    }

    func testRemovesLastStaleManagedKeyAndInsertsNewKeepingComments() {
        let base = """
        {
          // 顶层注释
          "model": "aiusage-old/m",
          "provider": {
            // provider 注释
            "openrouter": { "npm": "@ai-sdk/openai-compatible" },
            "aiusage-old": { "npm": "@ai-sdk/openai-compatible" }
          }
        }
        """
        let target: [String: Any] = [
            "model": "aiusage-new/m",
            "provider": [
                "openrouter": ["npm": "@ai-sdk/openai-compatible"],
                "aiusage-new": managedEntry("New", base: "https://n/v1"),
            ],
        ]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result, "删除最后一个受管键 + 新增受管键不应导致 merge 失败（重叠编辑）")
        let out = result!
        XCTAssertTrue(out.contains("// 顶层注释"), "顶层注释应保留")
        XCTAssertTrue(out.contains("// provider 注释"), "provider 内注释应保留")
        XCTAssertFalse(out.contains("aiusage-old"), "陈旧受管键应被移除")
        XCTAssertTrue(out.contains("aiusage-new"), "新受管键应插入")
        XCTAssertEqualJSON(parse(out), target)
    }

    // MARK: - Safety / Fallback

    func testReturnsNilForUnparsableBase() {
        XCTAssertNil(JSONCEditor.merge(baseText: "not json at all", target: ["a": 1]))
    }

    func testReturnsNilWhenRootNotObject() {
        XCTAssertNil(JSONCEditor.merge(baseText: "[1,2,3]", target: ["a": 1]))
    }

    func testIdempotentWhenAlreadyMatchesKeepsComments() {
        let base = """
        {
          // stable
          "model": "aiusage-x/foo"
        }
        """
        let target: [String: Any] = ["model": "aiusage-x/foo"]
        let result = JSONCEditor.merge(baseText: base, target: target)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.contains("// stable"))
        XCTAssertEqualJSON(parse(result!), target)
    }

    // MARK: - JSON equality assert

    private func XCTAssertEqualJSON(_ lhs: [String: Any]?, _ rhs: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        guard let lhs else {
            XCTFail("解析结果为 nil", file: file, line: line)
            return
        }
        XCTAssertTrue(NSDictionary(dictionary: lhs).isEqual(to: rhs), "结构应与目标一致\n实际: \(lhs)\n期望: \(rhs)", file: file, line: line)
    }
}
