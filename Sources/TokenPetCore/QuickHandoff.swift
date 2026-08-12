import Foundation

public struct QuickHandoffFacts: Equatable, Sendable {
    public var sourceThreadID: String
    public var title: String
    public var cwd: String
    public var userMessages: [String]
    public var publicAgentMessages: [String]
    public var changedFiles: [String]

    public init(
        sourceThreadID: String,
        title: String,
        cwd: String,
        userMessages: [String] = [],
        publicAgentMessages: [String] = [],
        changedFiles: [String] = []
    ) {
        self.sourceThreadID = sourceThreadID
        self.title = title
        self.cwd = cwd
        self.userMessages = userMessages
        self.publicAgentMessages = publicAgentMessages
        self.changedFiles = changedFiles
    }
}

public struct QuickHandoffCapsule: Equatable, Sendable {
    public var text: String
    public var sourceBytesRead: Int
    public var sourceMessagesUsed: Int

    public init(text: String, sourceBytesRead: Int, sourceMessagesUsed: Int) {
        self.text = text
        self.sourceBytesRead = sourceBytesRead
        self.sourceMessagesUsed = sourceMessagesUsed
    }
}

public struct QuickHandoffDiagnostics: Equatable, Sendable {
    public var sourceBytesRead: Int
    public var userMessages: Int
    public var publicAgentMessages: Int
    public var changedFiles: Int
    public var hasInheritedHandoff: Bool
    public var hasStructuredAgentSummary: Bool
    public var structuredHasState: Bool
    public var structuredHasVerified: Bool
    public var structuredHasConstraints: Bool
    public var substantiveUserMessages: Int
    public var substantiveAgentMessages: Int
    public var candidateUTF8Bytes: Int?
    public var buildSucceeded: Bool
}

public enum QuickHandoffCapsuleCompiler {
    public static let maximumCapsuleUTF8Bytes = 1_500
    public static let maximumSourceBytes = 4 * 1024 * 1024

    public static func compile(
        sourceThreadID: String,
        title: String,
        cwd: String,
        rolloutPath: String? = nil
    ) throws -> QuickHandoffCapsule? {
        let path = try rolloutPath ?? CodexRolloutTailer.rolloutPath(threadID: sourceThreadID)
        let extracted = try extractFacts(
            sourceThreadID: sourceThreadID,
            title: title,
            cwd: cwd,
            rolloutPath: path)
        guard let text = build(facts: extracted.facts), validate(text) else { return nil }
        return QuickHandoffCapsule(
            text: text,
            sourceBytesRead: extracted.bytesRead,
            sourceMessagesUsed: extracted.messagesUsed)
    }

    public static func diagnostics(
        sourceThreadID: String,
        title: String,
        cwd: String,
        rolloutPath: String? = nil
    ) throws -> QuickHandoffDiagnostics {
        let path = try rolloutPath ?? CodexRolloutTailer.rolloutPath(threadID: sourceThreadID)
        let extracted = try extractFacts(
            sourceThreadID: sourceThreadID,
            title: title,
            cwd: cwd,
            rolloutPath: path)
        let facts = extracted.facts
        let structuredMessage = facts.publicAgentMessages.reversed().first(where: isCompleteStructuredSummary)
        let candidate = build(facts: facts, enforceByteLimit: false)
        return QuickHandoffDiagnostics(
            sourceBytesRead: extracted.bytesRead,
            userMessages: facts.userMessages.count,
            publicAgentMessages: facts.publicAgentMessages.count,
            changedFiles: facts.changedFiles.count,
            hasInheritedHandoff: facts.userMessages.contains { $0.contains("<tokenpet_handoff>") },
            hasStructuredAgentSummary: structuredMessage != nil,
            structuredHasState: structuredMessage.flatMap {
                section("当前状态", in: $0) ?? section("Current state", in: $0)
            }.map(isSubstantive) ?? false,
            structuredHasVerified: structuredMessage.flatMap {
                verifiedSection(in: $0)
            }.map(isSubstantive) ?? false,
            structuredHasConstraints: structuredMessage.flatMap {
                section("不可变约束与风险", in: $0)
                    ?? section("Immutable constraints and risks", in: $0)
                    ?? section("Constraints", in: $0)
            }.map(isSubstantive) ?? false,
            substantiveUserMessages: facts.userMessages.map(sanitize)
                .filter { !isHandoffControlInstruction($0) && isSubstantive($0) }.count,
            substantiveAgentMessages: facts.publicAgentMessages.map(sanitize)
                .filter(isSubstantive).count,
            candidateUTF8Bytes: candidate?.utf8.count,
            buildSucceeded: candidate.map(validate) ?? false)
    }

    public static func build(facts: QuickHandoffFacts) -> String? {
        build(facts: facts, enforceByteLimit: true)
    }

    private static func build(facts: QuickHandoffFacts, enforceByteLimit: Bool) -> String? {
        let users = facts.userMessages
            .filter { !$0.contains("<tokenpet_handoff>") }
            .map(sanitize)
            .filter { !isHandoffControlInstruction($0) }
            .filter(isSubstantive)
        let rawAgents = facts.publicAgentMessages.filter(isSubstantive)
        let agents = rawAgents.map(sanitize).filter(isSubstantive).uniqued()
        let inherited = facts.userMessages.reversed().first(where: { $0.contains("<tokenpet_handoff>") })
        let latestStructured = rawAgents.reversed().first(where: isCompleteStructuredSummary)

        let inheritedGoal = inherited.flatMap { section("目标", in: $0) ?? section("Goal", in: $0) }
        let inheritedState = inherited.flatMap {
            section("当前状态", in: $0) ?? section("Current state", in: $0)
        }
        let inheritedVerified = inherited.flatMap {
            verifiedSection(in: $0)
        }
        let inheritedConstraints = inherited.flatMap {
            section("不可变约束与风险", in: $0)
                ?? section("Immutable constraints and risks", in: $0)
                ?? section("Constraints", in: $0)
        }
        let inheritedNext = inherited.flatMap { section("下一步", in: $0) ?? section("Next step", in: $0) }
        let structuredGoal = latestStructured.flatMap { section("目标", in: $0) ?? section("Goal", in: $0) }
        let structuredState = latestStructured.flatMap {
            section("当前状态", in: $0) ?? section("Current state", in: $0)
        }
        let structuredVerified = latestStructured.flatMap {
            verifiedSection(in: $0)
        }
        let structuredConstraints = latestStructured.flatMap {
            section("不可变约束与风险", in: $0)
                ?? section("Immutable constraints and risks", in: $0)
                ?? section("Constraints", in: $0)
        }
        let structuredNext = latestStructured.flatMap {
            section("下一步", in: $0) ?? section("Next step", in: $0)
        }
        let titleGoal = sanitize(facts.title)
        let goal = structuredGoal
            ?? inheritedGoal
            ?? (isSubstantiveTitle(titleGoal) ? titleGoal : nil)
            ?? users.last
        guard let goal,
              isSubstantive(goal) || (goal == titleGoal && isSubstantiveTitle(titleGoal)),
              isSubstantive(facts.cwd)
        else { return nil }

        let latestAgent = agents.last
        let previousAgent = agents.dropLast().last
        let currentState = structuredState.map(sanitize) ?? latestAgent ?? inheritedState.map(sanitize)
        let verified = structuredVerified.map(sanitize)
            ?? previousAgent
            ?? inheritedVerified.map(sanitize)
            ?? latestAgent
        guard let currentState, let verified,
              isSubstantive(currentState), isSubstantive(verified)
        else { return nil }
        let constraints = structuredConstraints.map(sanitize)
            ?? inheritedConstraints.map(sanitize)
            ?? "未从允许的公开事件中发现额外约束；不得扩大原任务权限。"
        let next = structuredNext.map(sanitize) ?? users.last ?? inheritedNext.map(sanitize) ?? latestAgent
        guard let next, isSubstantive(next) else { return nil }

        let workspaceRoot = URL(fileURLWithPath: facts.cwd).standardizedFileURL.path
        let changed = Array(facts.changedFiles.uniqued().filter { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return standardized == workspaceRoot || standardized.hasPrefix(workspaceRoot + "/")
        }.suffix(4))
        let workspaceLines = (["工作目录：\(sanitize(facts.cwd))"] + changed.map {
            "变更：\(sanitize($0))"
        }).joined(separator: "；")
        let method = "由 Guardian 从公开事件和本地事实确定性编译；未使用模型总结。"

        let text = """
        # 目标
        \(compact(goal, maximumBytes: 160))
        # 当前状态
        \(compact(currentState, maximumBytes: 160))
        # 已验证完成与证据
        \(compact(verified, maximumBytes: 160))
        # 关键决策与理由
        \(compact(method, maximumBytes: 110))
        # 不可变约束与风险
        \(compact(constraints, maximumBytes: 130))
        # 工作区、分支与变更文件
        \(compact(workspaceLines, maximumBytes: 180))
        # 下一步
        \(compact(next, maximumBytes: 160))
        """
        if enforceByteLimit, text.utf8.count > maximumCapsuleUTF8Bytes { return nil }
        return text
    }

    public static func validate(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= maximumCapsuleUTF8Bytes else { return false }
        let headings = [
            "# 目标", "# 当前状态", "# 已验证完成与证据", "# 关键决策与理由",
            "# 不可变约束与风险", "# 工作区、分支与变更文件", "# 下一步",
        ]
        guard headings.allSatisfy(text.contains) else { return false }
        let required = ["目标", "当前状态", "工作区、分支与变更文件", "下一步"]
        return required.allSatisfy { heading in
            guard let value = section(heading, in: text) else { return false }
            return heading == "目标" ? isSubstantiveTitle(value) : isSubstantive(value)
        }
    }

    private static func extractFacts(
        sourceThreadID: String,
        title: String,
        cwd: String,
        rolloutPath: String
    ) throws -> (facts: QuickHandoffFacts, bytesRead: Int, messagesUsed: Int) {
        let url = URL(fileURLWithPath: rolloutPath)
        let attributes = try FileManager.default.attributesOfItem(atPath: rolloutPath)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = size > UInt64(maximumSourceBytes) ? size - UInt64(maximumSourceBytes) : 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var users: [String] = []
        var agents: [String] = []
        var changedFiles: [String] = []
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String,
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            let eventType = payload["type"] as? String ?? ""
            if type == "event_msg", eventType == "user_message", let message = payload["message"] as? String {
                appendBounded(message, to: &users)
            } else if type == "event_msg", eventType == "agent_message",
                      payload["phase"] as? String == "final_answer",
                      let message = payload["message"] as? String {
                appendBounded(message, to: &agents)
            } else if type == "event_msg", eventType == "task_complete",
                      let message = payload["last_agent_message"] as? String {
                appendBounded(message, to: &agents)
            } else if type == "event_msg", eventType == "patch_apply_end",
                      let changes = payload["changes"] as? [String: Any] {
                for path in changes.keys.sorted() { appendBounded(path, to: &changedFiles, limit: 20) }
            } else if type == "response_item", eventType == "message",
                      let role = payload["role"] as? String,
                      let content = payload["content"] as? [[String: Any]] {
                let texts = content.compactMap { item -> String? in
                    let itemType = item["type"] as? String
                    guard itemType == "input_text" || itemType == "output_text" else { return nil }
                    return item["text"] as? String
                }
                for text in texts {
                    if role == "user" { appendBounded(text, to: &users) }
                    else if role == "assistant" { appendBounded(text, to: &agents) }
                }
            }
        }
        let facts = QuickHandoffFacts(
            sourceThreadID: sourceThreadID,
            title: title,
            cwd: cwd,
            userMessages: users,
            publicAgentMessages: agents,
            changedFiles: changedFiles)
        return (facts, data.count, users.count + agents.count)
    }

    private static func appendBounded(_ value: String, to values: inout [String], limit: Int = 12) {
        values.append(value)
        if values.count > limit { values.removeFirst(values.count - limit) }
    }

    private static func sanitize(_ value: String) -> String {
        var result = value
        let patterns = [
            #"(?s)<oai-mem-citation>.*?</oai-mem-citation>"#,
            #"(?s)```.*?```"#,
            #"https?://[^\s)>]+"#,
            #"(?i)(api[_-]?key|access[_-]?token|password|secret|authorization)\s*[:=]\s*[^\s,;]+"#,
        ]
        let replacements = ["", "[代码块已省略]", "[链接已省略]", "$1=[已脱敏]"]
        for (pattern, replacement) in zip(patterns, replacements) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: replacement)
        }
        result = result.replacingOccurrences(of: "<tokenpet_handoff>", with: "")
            .replacingOccurrences(of: "</tokenpet_handoff>", with: "")
        return result.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func section(_ heading: String, in text: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: heading)
        let pattern = "(?s)(?:^|\\n)#\\s*\(escaped)\\s*\\n(.*?)(?=\\n#\\s|$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verifiedSection(in text: String) -> String? {
        section("已验证完成与证据", in: text)
            ?? section("已验证完成", in: text)
            ?? section("已完成与证据", in: text)
            ?? section("Verified work and evidence", in: text)
            ?? section("Verified", in: text)
    }

    private static func isCompleteStructuredSummary(_ text: String) -> Bool {
        let values = [
            section("目标", in: text) ?? section("Goal", in: text),
            section("当前状态", in: text) ?? section("Current state", in: text),
            verifiedSection(in: text),
            section("不可变约束与风险", in: text)
                ?? section("Immutable constraints and risks", in: text)
                ?? section("Constraints", in: text),
            section("下一步", in: text) ?? section("Next step", in: text),
        ]
        return values.allSatisfy { $0.map(isSubstantive) ?? false }
    }

    private static func compact(_ value: String, maximumBytes: Int) -> String {
        let sanitized = sanitize(value)
        var result = ""
        var bytes = 0
        for character in sanitized {
            let next = String(character)
            let count = next.utf8.count
            guard bytes + count <= maximumBytes else { break }
            result.append(character)
            bytes += count
        }
        guard result != sanitized else { return result }
        result = result.trimmingCharacters(in: .whitespaces)
        let ellipsis = "…"
        while !result.isEmpty && result.utf8.count + ellipsis.utf8.count > maximumBytes {
            result.removeLast()
        }
        return result + ellipsis
    }

    private static func isSubstantive(_ value: String) -> Bool {
        let compacted = sanitize(value)
        let acknowledgements = Set(["继续", "可以", "好的", "收到", "继续实现", "继续执行", "ok", "continue"])
        return compacted.count >= 8 && !acknowledgements.contains(compacted.lowercased())
    }

    private static func isSubstantiveTitle(_ value: String) -> Bool {
        let compacted = sanitize(value)
        let generic = Set(["新任务", "续接任务", "untitled", "new task"])
        return compacted.count >= 4 && !generic.contains(compacted.lowercased())
    }

    private static func isHandoffControlInstruction(_ value: String) -> Bool {
        let normalized = sanitize(value).lowercased()
        let markers = [
            "生成一份结构化交接摘要",
            "仅使用此任务中已经存在的上下文",
            "本回合不要调用工具或修改文件",
            "请确认收到，并用一句话复述",
            "generate a structured handoff",
        ]
        return markers.contains { normalized.contains($0) }
    }
}

private extension Array where Element == String {
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
