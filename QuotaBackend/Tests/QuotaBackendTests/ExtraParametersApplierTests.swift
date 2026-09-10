import XCTest
@testable import QuotaBackend

/// 覆盖 issue #69 每模型追加参数的解析与合并：标量/结构化解析、点路径、父子路径冲突确定性、
/// 无效 JSON 风格输入的明确行为。
final class ExtraParametersApplierTests: XCTestCase {

    // MARK: - parseParameterValue 标量

    func testParseParameterValueScalars() {
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("hello") as? String, "hello")
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("123") as? Int, 123)
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("-42") as? Int, -42)
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("1.5") as? Double, 1.5)
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("true") as? Bool, true)
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("false") as? Bool, false)
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("TRUE") as? Bool, true)
    }

    func testParseParameterValueNullAndEmpty() {
        XCTAssertTrue(ExtraParametersApplier.parseParameterValue("null") is NSNull)
        XCTAssertTrue(ExtraParametersApplier.parseParameterValue("nil") is NSNull)
        XCTAssertNil(ExtraParametersApplier.parseParameterValue(""))
        XCTAssertNil(ExtraParametersApplier.parseParameterValue("   "))
    }

    // MARK: - parseParameterValue 结构化

    func testParseParameterValueStructured() {
        let object = ExtraParametersApplier.parseParameterValue(#"{"a":1,"b":"x"}"#) as? [String: Any]
        XCTAssertEqual(object?["a"] as? Int, 1)
        XCTAssertEqual(object?["b"] as? String, "x")

        let array = ExtraParametersApplier.parseParameterValue("[1,2,3]") as? [Any]
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[0] as? Int, 1)
    }

    func testParseParameterValueInvalidJSONKeptAsString() {
        // 以 { 或 [ 开头但解析失败：原样保留为字符串（明确、可测试，不会静默丢弃）。
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("{not valid}") as? String, "{not valid}")
        XCTAssertEqual(ExtraParametersApplier.parseParameterValue("[unclosed") as? String, "[unclosed")
    }

    // MARK: - applyExtraParameters 点路径与冲突

    func testApplyExtraParametersDotPath() {
        let result = ExtraParametersApplier.applyExtraParameters(
            ["limit.context": "8192", "limit.output": "4096"],
            to: [:]
        )
        let limit = result["limit"] as? [String: Any]
        XCTAssertEqual(limit?["context"] as? Int, 8192)
        XCTAssertEqual(limit?["output"] as? Int, 4096)
    }

    func testApplyExtraParametersOverridesExistingEntry() {
        let result = ExtraParametersApplier.applyExtraParameters(
            ["temperature": "0.7", "reasoning.effort": "high"],
            to: ["temperature": 1.0]
        )
        XCTAssertEqual(result["temperature"] as? Double, 0.7)
        let reasoning = result["reasoning"] as? [String: Any]
        XCTAssertEqual(reasoning?["effort"] as? String, "high")
    }

    func testApplyExtraParametersParentChildConflictDeterministic() {
        // 父子路径冲突（"limit" 与 "limit.context"）：按 key 字典序排序后父路径先写、
        // 子路径后写覆盖，结果确定，不依赖字典遍历顺序。最终 limit 是嵌套字典，子路径生效。
        let result = ExtraParametersApplier.applyExtraParameters(
            ["limit": "10", "limit.context": "8192"],
            to: [:]
        )
        let limit = result["limit"] as? [String: Any]
        XCTAssertNotNil(limit, "子路径应覆盖父路径标量，最终 limit 是嵌套字典")
        XCTAssertEqual(limit?["context"] as? Int, 8192)
    }

    func testApplyExtraParametersSkipsEmptyValue() {
        // 空值解析为 nil，apply 跳过该 key，不写入。
        let result = ExtraParametersApplier.applyExtraParameters(
            ["skip": "  ", "keep": "42"],
            to: [:]
        )
        XCTAssertNil(result["skip"])
        XCTAssertEqual(result["keep"] as? Int, 42)
    }
}
