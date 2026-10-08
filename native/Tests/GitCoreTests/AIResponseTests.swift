// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import XCTest
@testable import GitCore

final class AIResponseTests: XCTestCase {
    private func response(content: Any = NSNull(), reason: String = "stop", extra: [String: Any] = [:]) throws -> Data {
        let message = ["content": content].merging(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [
            "choices": [["finish_reason": reason, "message": message]],
            "usage": ["completion_tokens": 4096, "completion_tokens_details": ["reasoning_tokens": extra["reasoning_content"] == nil ? 0 : 4096]]
        ])
    }

    func testEmptyTruncatedReasoningReportsTheActualStopCause() throws {
        let data = try response(reason: "length", extra: ["reasoning_content": "private-analysis-must-not-leak"])
        XCTAssertThrowsError(try AIClient.parseResponse(data)) { error in
            XCTAssertTrue(error.localizedDescription.contains("截断"))
            XCTAssertTrue(error.localizedDescription.contains("思考"))
            XCTAssertTrue(error.localizedDescription.contains("4096"))
            XCTAssertFalse(error.localizedDescription.contains("private-analysis"))
            XCTAssertFalse(error.localizedDescription.contains("检查接口兼容性和模型名称"))
        }
    }

    func testReasoningIsNeverUsedAsTheCommitMessage() throws {
        XCTAssertThrowsError(try AIClient.parseResponse(response(extra: ["reasoning_content": "private-analysis"]))) { error in
            XCTAssertTrue(error.localizedDescription.contains("仅返回了思考内容"))
            XCTAssertFalse(error.localizedDescription.contains("private-analysis"))
        }
        XCTAssertEqual(try AIClient.parseResponse(response(content: "fix: 修正输入", extra: ["reasoning_content": "private-analysis"])), "fix: 修正输入")
    }

    func testBlockedAndToolResponsesCannotBecomeCommitMessages() throws {
        for (reason, extra, expected) in [
            ("content_filter", [:], "内容过滤"),
            ("stop", ["refusal": "private-refusal-text"], "拒绝"),
            ("tool_calls", ["tool_calls": [["id": "test-tool"]]], "工具调用")
        ] as [(String, [String: Any], String)] {
            XCTAssertThrowsError(try AIClient.parseResponse(response(content: "partial answer", reason: reason, extra: extra))) { error in
                XCTAssertTrue(error.localizedDescription.contains(expected))
                XCTAssertFalse(error.localizedDescription.contains("private-refusal"))
                XCTAssertFalse(error.localizedDescription.contains("partial answer"))
            }
        }
    }

    func testTextPartsAreCombinedButNonTextPartsAreNotSilentlyDropped() throws {
        let parts = [["type": "text", "text": "feat: 添加筛选\n"], ["type": "text", "text": "\n- 支持按状态筛选"]]
        XCTAssertEqual(try AIClient.parseResponse(response(content: parts)), "feat: 添加筛选\n\n- 支持按状态筛选")
        XCTAssertThrowsError(try AIClient.parseResponse(response(content: parts + [["type": "image_url", "text": "not a final answer"]])))
    }

    func testEmptyEnvelopeAndNormalizedEmptyTextHaveDifferentDiagnostics() throws {
        XCTAssertThrowsError(try AIClient.parseResponse(Data("{}".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("响应格式"))
        }
        XCTAssertThrowsError(try AIClient.parseResponse(response(content: " \n"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("正文为空"))
        }
        XCTAssertThrowsError(try AIClient.parseResponse(response(content: "```text\n \n```")))
        let serviceError = Data(#"{"error":{"message":"private-provider-detail","code":"error"}}"#.utf8)
        XCTAssertThrowsError(try AIClient.parseResponse(serviceError)) { error in
            XCTAssertTrue(error.localizedDescription.contains("错误对象"))
            XCTAssertFalse(error.localizedDescription.contains("private-provider-detail"))
        }
    }

    func testSupportedQwenCommitUsesDirectOutputWithoutChangingReviewOrOtherProviders() throws {
        let context = AIContext(stamp: .init(head: "test", branch: "refs/heads/main", indexHash: "test"), included: ["demo.txt"], excluded: [], patch: "+new title", whitespaceResult: "未执行测试")
        for (url, model, intent, direct) in [
            ("https://test.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "qwen3.8-flash", AIIntent.commit, true),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-flash", .commit, true),
            ("https://test.cn-beijing.maas.aliyuncs.com/compatible-mode/v1", "qwen3.8-flash", .review, false),
            ("https://proxy.example.invalid/v1", "qwen3.8-flash", .commit, false),
            ("https://maas.aliyuncs.com.example.invalid/v1", "qwen3.8-flash", .commit, false),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen3.8-27b-thinking", .commit, false),
            ("https://dashscope.aliyuncs.com/compatible-mode/v1", "fixture-model", .commit, false)
        ] {
            var config = AIConfiguration(); config.baseURL = url; config.model = model
            let request = try AIClient().request(context: context, configuration: config, key: "", intent: intent)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            if direct { XCTAssertEqual(body["enable_thinking"] as? Bool, false) }
            else { XCTAssertNil(body["enable_thinking"]) }
            XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        }
    }
}
