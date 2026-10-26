// Copyright (c) 2026 zhiyu
// SPDX-License-Identifier: LicenseRef-Sprig-NC-SA-1.0

import Foundation

/// One user operation may contain several network commands. Cancellation stops
/// transport immediately. Synchronized push finishes local integration/restoration
/// at a safe boundary; callers must not expose cancellation for a combined git pull.
/// Progress runs on the command worker, at most four times per second plus a final update.
public final class GitNetworkOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let idleTimeout: TimeInterval
    let maximumDuration: TimeInterval
    let progress: @Sendable (String) -> Void

    public convenience init(progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(idleTimeout: 600, maximumDuration: 7_200, progress: progress)
    }
    init(idleTimeout: TimeInterval, maximumDuration: TimeInterval, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.idleTimeout = idleTimeout; self.maximumDuration = maximumDuration; self.progress = progress
    }
    public func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func checkCancellation() throws { if isCancelled { throw CancellationError() } }
}

/// Only standard numeric Git progress is forwarded to the UI. URLs, credential
/// helper output and arbitrary server/hook text remain out of the live status.
struct GitProgressParser {
    private var line = Data()
    private var oversized = false
    private static let phases = [
        "Enumerating objects": "枚举对象", "Counting objects": "统计对象",
        "Compressing objects": "压缩对象", "Writing objects": "上传对象",
        "Receiving objects": "接收对象", "Resolving deltas": "解析增量",
        "Updating files": "更新文件", "Checking connectivity": "检查连接"
    ]
    private static let numbers = try! NSRegularExpression(pattern:
        #"^(?:([0-9]{1,3})% \([0-9]{1,12}/[0-9]{1,12}\)|([0-9]{1,12}))(?:, ([0-9]+(?:\.[0-9]+)? (?:[KMGT]?i?B|bytes))(?: \| ([0-9]+(?:\.[0-9]+)? (?:[KMGT]?i?B|bytes)/s))?)?(?:, done\.)?[ ]*$"#)

    mutating func append(_ chunk: Data) -> String? {
        var latest: String?
        for byte in chunk {
            if byte == 10 || byte == 13 {
                if !oversized, let parsed = Self.parse(String(decoding: line, as: UTF8.self)) { latest = parsed }
                line.removeAll(keepingCapacity: true); oversized = false
            } else if line.count < 512, !oversized { line.append(byte) }
            else { oversized = true }
        }
        return latest
    }
    private static func parse(_ raw: String) -> String? {
        let remote = raw.hasPrefix("remote: ")
        let text = remote ? String(raw.dropFirst(8)) : raw
        guard let separator = text.range(of: ": "), let phase = phases[String(text[..<separator.lowerBound])] else { return nil }
        let detail = String(text[separator.upperBound...])
        guard let match = numbers.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)) else { return nil }
        func field(_ index: Int) -> String? { Range(match.range(at: index), in: detail).map { String(detail[$0]) } }
        var fields = [(remote ? "远端" : "") + phase]
        if let percent = field(1) {
            guard (Int(percent) ?? 101) <= 100 else { return nil }
            fields.append(percent + "%")
        } else if let count = field(2) { fields.append(count) }
        if let bytes = field(3) { fields.append(bytes) }
        if let rate = field(4) { fields.append(rate) }
        return fields.joined(separator: " · ")
    }
}
