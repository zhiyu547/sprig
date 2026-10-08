// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

/// Only final answer text can become a draft. Diagnostics contain status and
/// token counts, never provider error bodies, refusal text or reasoning content.
enum AIResponseParser {
    static func parse(_ data: Data) throws -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw GitError.message("AI 接口返回的响应格式不是 JSON；请使用非流式 Chat Completions 接口。")
        }
        if let error = object["error"], !(error is NSNull) {
            throw GitError.message("AI 服务返回了错误对象，而非生成结果。请查看服务端调用记录；原草稿已保留。")
        }
        guard let choices = object["choices"] as? [[String: Any]], let choice = choices.first else {
            throw GitError.message("AI 响应格式不兼容：缺少 Chat Completions 的 choices 结果。原草稿已保留。")
        }
        let message = choice["message"] as? [String: Any] ?? [:]
        let reason = choice["finish_reason"] as? String
        let usage = object["usage"] as? [String: Any] ?? [:]
        let reasoningTokens = (usage["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        let hasReasoning = !(message["reasoning_content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (reasoningTokens ?? 0) > 0
        var diagnostic: [String] = []
        if let reason, ["stop", "length", "content_filter", "tool_calls", "function_call"].contains(reason) { diagnostic.append("结束原因：" + reason) }
        if let tokens = usage["completion_tokens"] as? Int, tokens >= 0 { diagnostic.append("输出 Token：\(tokens)") }
        if let tokens = reasoningTokens, tokens >= 0 { diagnostic.append("思考 Token：\(tokens)") }
        func failure(_ explanation: String) -> GitError {
            .message(explanation + (diagnostic.isEmpty ? "" : "\n" + diagnostic.joined(separator: "；")))
        }

        // Inspect the stop cause before requiring content: a truncated reasoning
        // response legitimately has null/empty content, not an invalid model name.
        if reason == "length" {
            throw failure("AI 输出达到长度上限，已截断。" + (hasReasoning ? "本次包含思考内容；思考与最终正文的额度需按服务规则配置。" : "") + "未采用不完整结果，原草稿已保留。")
        }
        if reason == "content_filter" { throw failure("AI 服务触发内容过滤，未返回完整结果；原草稿已保留。") }
        if !(message["refusal"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw failure("模型拒绝生成本次内容；原草稿已保留。")
        }
        if reason == "tool_calls" || reason == "function_call" || !(message["tool_calls"] as? [Any] ?? []).isEmpty || message["function_call"] as? [String: Any] != nil {
            throw failure("模型返回了工具调用，没有完整的提交说明；请使用支持直接文本输出的模型。原草稿已保留。")
        }
        guard choice["message"] is [String: Any] else {
            throw failure("AI 响应格式不兼容：缺少完整的 message 结果；请使用非流式 Chat Completions 接口。")
        }
        var text: String
        if let content = message["content"] as? String {
            text = content
        } else if let parts = message["content"] as? [[String: Any]] {
            text = try parts.map { part in
                if part["type"] as? String == "refusal" { throw failure("模型拒绝生成本次内容；原草稿已保留。") }
                guard let type = part["type"] as? String, ["text", "output_text"].contains(type), let content = part["text"] as? String else {
                    throw failure("AI 响应格式包含不支持的内容块，未将部分文本作为完整结果。")
                }
                return content
            }.joined()
        } else if message["content"] == nil || message["content"] is NSNull {
            text = ""
        } else {
            throw failure("AI 响应格式不兼容：content 应为正文或文本内容块。")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```") {
            let lines = text.components(separatedBy: "\n")
            if lines.count > 2 { text = lines.dropFirst().dropLast().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !text.isEmpty else {
            throw failure(hasReasoning
                          ? "模型仅返回了思考内容，最终正文为空；不能用思考过程代替提交说明，原草稿已保留。"
                          : "AI 服务返回成功，但最终正文为空；请重试或查看服务端调用记录，原草稿已保留。")
        }
        guard text.utf8.count <= 100_000, !text.contains("\0") else { throw failure("AI 返回内容过长或包含不支持的字符。") }
        return text
    }
}
