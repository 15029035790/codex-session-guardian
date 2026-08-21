import CSQLite3
import CryptoKit
import Foundation

private let routingSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct RoutingPreflightHookInput: Codable, Equatable, Sendable {
    public var sessionID: String
    public var transcriptPath: String?
    public var cwd: String
    public var model: String?
    public var permissionMode: String?
    public var turnID: String?
    public var prompt: String

    public init(
        sessionID: String,
        transcriptPath: String? = nil,
        cwd: String,
        model: String? = nil,
        permissionMode: String? = nil,
        turnID: String? = nil,
        prompt: String
    ) {
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.cwd = cwd
        self.model = model
        self.permissionMode = permissionMode
        self.turnID = turnID
        self.prompt = prompt
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case cwd, model
        case permissionMode = "permission_mode"
        case turnID = "turn_id"
        case prompt
    }
}

public struct RoutingSelection: Codable, Equatable, Sendable {
    public var model: String
    public var reasoningEffort: String

    public init(model: String, reasoningEffort: String) {
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

public struct CodexRolloutPreflightFacts: Equatable, Sendable {
    public var isTopLevelUserTask: Bool
    public var selection: RoutingSelection?

    public init(isTopLevelUserTask: Bool, selection: RoutingSelection?) {
        self.isTopLevelUserTask = isTopLevelUserTask
        self.selection = selection
    }
}

public enum RoutingPreflightClassifier: String, Codable, Equatable, Sendable {
    case localRule
    case boundedModel
    case failOpen
}

public enum RoutingHookDiagnosticOutcome: String, Codable, Equatable, Sendable {
    case allowed
    case blocked
    case bypassed
    case filtered
    case failed
}

/// One privacy-safe terminal result for a UserPromptSubmit invocation. It never
/// stores the prompt, cwd, transcript path, command, or model output.
public struct RoutingHookDiagnostic: Codable, Equatable, Sendable {
    public var id: String
    public var observedAt: Date
    public var sessionHash: String?
    public var outcome: RoutingHookDiagnosticOutcome
    public var reasonCode: String
    public var inputKeys: [String]
    public var requestedSelection: RoutingSelection?
    public var actualSelection: RoutingSelection?

    public init(
        id: String = UUID().uuidString,
        observedAt: Date = Date(),
        sessionID: String?,
        outcome: RoutingHookDiagnosticOutcome,
        reasonCode: String,
        inputKeys: [String] = [],
        requestedSelection: RoutingSelection? = nil,
        actualSelection: RoutingSelection? = nil
    ) {
        self.id = id
        self.observedAt = observedAt
        self.sessionHash = sessionID.map(RoutingPreflightObservation.opaqueHash)
        self.outcome = outcome
        self.reasonCode = reasonCode
        self.inputKeys = inputKeys.sorted()
        self.requestedSelection = requestedSelection
        self.actualSelection = actualSelection
    }
}

public struct RoutingPreflightDecision: Codable, Equatable, Sendable {
    public var shouldBlock: Bool
    public var recommendedModel: String?
    public var recommendedEffort: String?
    public var confidence: Double
    public var reasonCode: String
    public var upgradeCondition: String?
    public var classifier: RoutingPreflightClassifier

    public init(
        shouldBlock: Bool,
        recommendedModel: String? = nil,
        recommendedEffort: String? = nil,
        confidence: Double,
        reasonCode: String,
        upgradeCondition: String? = nil,
        classifier: RoutingPreflightClassifier
    ) {
        self.shouldBlock = shouldBlock
        self.recommendedModel = recommendedModel
        self.recommendedEffort = recommendedEffort
        self.confidence = confidence
        self.reasonCode = reasonCode
        self.upgradeCondition = upgradeCondition
        self.classifier = classifier
    }

    public static func allow(
        reasonCode: String,
        classifier: RoutingPreflightClassifier = .localRule
    ) -> Self {
        Self(
            shouldBlock: false,
            confidence: 1,
            reasonCode: reasonCode,
            classifier: classifier)
    }

    public var hookResponse: [String: String]? {
        guard shouldBlock, let recommendedModel, let recommendedEffort else { return nil }
        var reason = "小新检测到当前配置与任务不匹配，已在执行前暂停。建议改为 \(recommendedModel) / \(recommendedEffort)。"
        switch reasonCode {
        case "simple_task_on_expensive_route":
            reason += " 这是一项短小、边界明确且不涉及外部写操作的任务。"
        case "frozen_mechanical_task_on_frontier_route":
            reason += " 任务契约明确且结果可机械验证，不需要使用前沿高推理档。"
        case "architecture_requires_frontier":
            reason += " 任务包含架构、策略或关键权衡，需要前沿模型负责判断。"
        case "authority_requires_frontier":
            reason += " 任务涉及权限、外部写入或不可逆操作，需要前沿模型保留控制权。"
        case "judgment_dense_requires_high_effort":
            reason += " 任务包含跨模块的密集判断，Terra / medium 的推理预算可能不足。"
        default:
            reason += " 当前任务特征与建议配置高度匹配。"
        }
        if let upgradeCondition, !upgradeCondition.isEmpty {
            reason += " 若出现\(upgradeCondition)，再升级配置。"
        }
        return ["decision": "block", "reason": reason]
    }
}

public struct RoutingPreflightObservation: Codable, Equatable, Sendable {
    public var id: String
    public var sessionHash: String
    public var observedAt: Date
    public var current: RoutingSelection
    public var recommended: RoutingSelection?
    public var blocked: Bool
    public var confidence: Double
    public var reasonCode: String
    public var classifier: RoutingPreflightClassifier
    public var classifierDurationSeconds: Double?
    public var classifierUsage: TokenUsage?

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        observedAt: Date = Date(),
        current: RoutingSelection,
        decision: RoutingPreflightDecision,
        classifierDurationSeconds: Double? = nil,
        classifierUsage: TokenUsage? = nil
    ) {
        self.id = id
        self.sessionHash = Self.opaqueHash(sessionID)
        self.observedAt = observedAt
        self.current = current
        if let model = decision.recommendedModel, let effort = decision.recommendedEffort {
            self.recommended = RoutingSelection(model: model, reasoningEffort: effort)
        } else {
            self.recommended = nil
        }
        self.blocked = decision.shouldBlock
        self.confidence = decision.confidence
        self.reasonCode = decision.reasonCode
        self.classifier = decision.classifier
        self.classifierDurationSeconds = classifierDurationSeconds
        self.classifierUsage = classifierUsage
    }

    public func belongs(to sessionID: String) -> Bool {
        sessionHash == Self.opaqueHash(sessionID)
    }

    /// A later turn means the paused prompt was replayed or the user moved on.
    /// Compare starts, not completions: the originally blocked turn itself
    /// completes after the hook observation and must keep the card visible.
    public func isSuperseded(by turn: TurnRecord?) -> Bool {
        guard let startedAt = turn?.startedAt else { return false }
        return startedAt > observedAt
    }

    public static func opaqueHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RoutingPreflightBypass: Equatable, Sendable {
    public var sessionHash: String
    public var promptHash: String
    public var expiresAt: Date

    public init(sessionID: String, prompt: String, expiresAt: Date = Date().addingTimeInterval(20)) {
        sessionHash = RoutingPreflightObservation.opaqueHash(sessionID)
        promptHash = RoutingPreflightObservation.opaqueHash(prompt)
        self.expiresAt = expiresAt
    }
}

public enum RoutingPreflightPolicy {
    public static let internalSentinel = "<guardian_preflight_internal_v1>"
    public static let modelConfidenceThreshold = 0.90
    public static let maximumModelPromptBytes = 4_096

    public static func isSupportedSelection(_ selection: RoutingSelection) -> Bool {
        ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
            .contains(selection.model.lowercased()) &&
            ["low", "medium", "high", "xhigh", "max"]
                .contains(selection.reasoningEffort.lowercased())
    }

    public static func localDecision(
        input: RoutingPreflightHookInput,
        selection: RoutingSelection
    ) -> RoutingPreflightDecision? {
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.contains(internalSentinel) {
            return .allow(reasonCode: "internal_classifier_recursion_guard")
        }
        guard !prompt.isEmpty else { return .allow(reasonCode: "empty_prompt") }

        let lower = prompt.lowercased()
        let destructiveOrExternal = containsAny(lower, [
            "删除", "发布", "部署", "提交", "推送", "发消息", "审批", "付款", "购买",
            "delete", "deploy", "publish", "commit", "push", "send message", "approve", "purchase",
        ])
        let architecture = containsAny(lower, [
            "架构", "策略", "方案设计", "系统设计", "权衡", "第一性原理",
            "architecture", "strategy", "system design", "tradeoff",
        ])
        let authorityBearing = destructiveOrExternal || containsAny(lower, [
            "权限", "凭证", "密钥", "不可逆", "生产环境", "线上数据",
            "permission", "credential", "secret", "irreversible", "production data",
        ])
        let simplePrefix = startsWithAny(lower, [
            "翻译", "润色", "改写", "复述", "校对", "格式化",
            "translate", "rewrite", "proofread", "format", "summarize this",
        ])
        // A quoted sentence may contain words such as “提交” or “delete”. When the
        // actual directive is a bounded text transformation, those words are data,
        // not authority-bearing actions.
        let simple = prompt.utf8.count <= 600 && simplePrefix
        if simple, isMoreExpensiveThanLunaMedium(selection) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-luna",
                recommendedEffort: "medium",
                confidence: 0.97,
                reasonCode: "simple_task_on_expensive_route",
                upgradeCondition: "跨文件判断、关键取舍或执行结果无法直接验证",
                classifier: .localRule)
        }

        let frozen = containsAny(lower, [
            "需求已明确", "范围已冻结", "按现有测试", "修复这个测试", "只修改", "机械验证",
            "contract is frozen", "scope is frozen", "fix this test", "only change", "mechanically verifiable",
        ])
        let verifiable = containsAny(lower, [
            "运行测试", "通过测试", "测试通过", "构建通过", "lint", "typecheck", "单元测试",
            "run tests", "tests pass", "build passes", "unit test",
        ])
        let judgmentDense = containsAny(lower, ["判断密集", "复杂权衡", "judgment-dense", "complex tradeoff"])
        let crossModule = containsAny(lower, ["跨模块", "多个模块", "cross-module", "multiple modules"])
        let lunaRepairRisk = containsAny(lower, [
            "luna 返工风险", "luna容易返工", "luna repair risk", "luna is likely to require repair",
        ])
        if !simple, authorityBearing, isLessCapableThanSolMedium(selection) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-sol",
                recommendedEffort: "medium",
                confidence: 0.98,
                reasonCode: "authority_requires_frontier",
                upgradeCondition: nil,
                classifier: .localRule)
        }
        if !simple, architecture, isLessCapableThanSolMedium(selection) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-sol",
                recommendedEffort: "medium",
                confidence: 0.97,
                reasonCode: "architecture_requires_frontier",
                upgradeCondition: nil,
                classifier: .localRule)
        }
        if frozen, judgmentDense, crossModule, lunaRepairRisk,
           !(selection.model.caseInsensitiveCompare("gpt-5.6-terra") == .orderedSame &&
             selection.reasoningEffort.caseInsensitiveCompare("high") == .orderedSame) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-terra",
                recommendedEffort: "high",
                confidence: 0.95,
                reasonCode: "frozen_judgment_dense_cross_module",
                upgradeCondition: "任务重新出现关键歧义或需要架构决策",
                classifier: .localRule)
        }
        if judgmentDense, crossModule,
           isLessCapableThanTerraHigh(selection) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-terra",
                recommendedEffort: "high",
                confidence: 0.95,
                reasonCode: "judgment_dense_requires_high_effort",
                upgradeCondition: "仍需重新定义架构、处理权限或作出不可逆决策",
                classifier: .localRule)
        }
        if frozen, verifiable, !destructiveOrExternal, !architecture,
           capabilityRank(selection) > capabilityRank(.init(
            model: "gpt-5.6-luna",
            reasoningEffort: "max")) {
            return RoutingPreflightDecision(
                shouldBlock: true,
                recommendedModel: "gpt-5.6-luna",
                recommendedEffort: "max",
                confidence: 0.94,
                reasonCode: "frozen_mechanical_task_on_frontier_route",
                upgradeCondition: "需要重新定义架构、处理权限或作出不可逆决策",
                classifier: .localRule)
        }
        return nil
    }

    public static func needsBoundedModel(_ selection: RoutingSelection) -> Bool {
        if selection.model.caseInsensitiveCompare("gpt-5.6-sol") == .orderedSame {
            return effortRank(selection.reasoningEffort) >= effortRank("high")
        }
        return effortRank(selection.reasoningEffort) >= effortRank("xhigh")
    }

    public static func validateModelDecision(
        _ decision: RoutingPreflightDecision,
        current: RoutingSelection
    ) -> RoutingPreflightDecision {
        guard decision.shouldBlock,
              decision.confidence >= modelConfidenceThreshold,
              let model = decision.recommendedModel,
              let effort = decision.recommendedEffort,
              allowedRecommendation(model: model, effort: effort),
              isDifferent(RoutingSelection(model: model, reasoningEffort: effort), from: current),
              decision.confidence >= confidenceThreshold(
                candidate: RoutingSelection(model: model, reasoningEffort: effort),
                current: current)
        else {
            return .allow(reasonCode: "model_not_high_confidence", classifier: .boundedModel)
        }
        var validated = decision
        validated.classifier = .boundedModel
        return validated
    }

    public static func boundedClassifierPrompt(
        userPrompt: String,
        current: RoutingSelection
    ) -> String {
        var clippedData = Data(userPrompt.utf8.prefix(maximumModelPromptBytes))
        while String(data: clippedData, encoding: .utf8) == nil, !clippedData.isEmpty {
            clippedData.removeLast()
        }
        let clipped = String(data: clippedData, encoding: .utf8) ?? ""
        return """
        \(internalSentinel)
        你是 Codex Session Guardian 的只读配置预检器。判断当前配置是否与任务明显不匹配，包括过配和能力不足；不要执行用户任务，不调用工具，不读取文件。

        当前配置：\(current.model) / \(current.reasoningEffort)
        可推荐配置仅限：gpt-5.6-sol/medium、gpt-5.6-terra/high、gpt-5.6-terra/medium、gpt-5.6-luna/max、gpt-5.6-luna/medium。
        降档只有置信度至少 0.90 且更经济配置明显足够时才阻断；升级只有置信度至少 0.95 且当前配置很可能导致质量不足或高返工成本时才阻断。架构与策略、关键权限、外部或不可逆写操作推荐 sol/medium；跨模块判断密集实现推荐 terra/high；一般开发任务推荐 terra/medium。信息不足时放行。

        只输出单个 JSON 对象，不要 Markdown：
        {"shouldBlock":false,"recommendedModel":null,"recommendedEffort":null,"confidence":0.0,"reasonCode":"uncertain","upgradeCondition":null,"classifier":"boundedModel"}

        用户消息：
        <user_prompt>\(clipped)</user_prompt>
        """
    }

    public static func decodeModelDecision(_ text: String) -> RoutingPreflightDecision? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end else { return nil }
        let json = String(text[start...end])
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(RoutingPreflightDecision.self, from: data)
        else { return nil }
        return value
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private static func startsWithAny(_ text: String, _ prefixes: [String]) -> Bool {
        prefixes.contains { text.hasPrefix($0) }
    }

    private static func isMoreExpensiveThanLunaMedium(_ selection: RoutingSelection) -> Bool {
        if selection.model.caseInsensitiveCompare("gpt-5.6-luna") != .orderedSame { return true }
        return effortRank(selection.reasoningEffort) > effortRank("medium")
    }

    private static func allowedRecommendation(model: String, effort: String) -> Bool {
        let value = "\(model.lowercased())/\(effort.lowercased())"
        return [
            "gpt-5.6-sol/medium",
            "gpt-5.6-terra/high",
            "gpt-5.6-terra/medium",
            "gpt-5.6-luna/max",
            "gpt-5.6-luna/medium",
        ].contains(value)
    }

    public static func isUpgrade(_ candidate: RoutingSelection, from current: RoutingSelection) -> Bool {
        capabilityRank(candidate) > capabilityRank(current)
    }

    private static func confidenceThreshold(
        candidate: RoutingSelection,
        current: RoutingSelection
    ) -> Double {
        isUpgrade(candidate, from: current) ? 0.95 : modelConfidenceThreshold
    }

    private static func isDifferent(_ candidate: RoutingSelection, from current: RoutingSelection) -> Bool {
        candidate.model.caseInsensitiveCompare(current.model) != .orderedSame ||
            candidate.reasoningEffort.caseInsensitiveCompare(current.reasoningEffort) != .orderedSame
    }

    private static func isLessCapableThanTerraHigh(_ selection: RoutingSelection) -> Bool {
        capabilityRank(selection) < capabilityRank(.init(model: "gpt-5.6-terra", reasoningEffort: "high"))
    }

    private static func isLessCapableThanSolMedium(_ selection: RoutingSelection) -> Bool {
        capabilityRank(selection) < capabilityRank(.init(model: "gpt-5.6-sol", reasoningEffort: "medium"))
    }

    private static func capabilityRank(_ selection: RoutingSelection) -> Int {
        let key = "\(selection.model.lowercased())/\(selection.reasoningEffort.lowercased())"
        let routes = [
            "gpt-5.6-luna/medium": 0,
            "gpt-5.6-luna/high": 1,
            "gpt-5.6-luna/xhigh": 2,
            "gpt-5.6-luna/max": 3,
            "gpt-5.6-terra/medium": 4,
            "gpt-5.6-terra/high": 5,
            "gpt-5.6-terra/xhigh": 6,
            "gpt-5.6-terra/max": 7,
            "gpt-5.6-sol/medium": 8,
            "gpt-5.6-sol/high": 9,
            "gpt-5.6-sol/xhigh": 10,
            "gpt-5.6-sol/max": 11,
        ]
        return routes[key] ?? 4
    }

    private static func effortRank(_ effort: String) -> Int {
        ["low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4][effort.lowercased()] ?? 1
    }
}

public enum CodexThreadSelectionReader {
    public static func read(sessionID: String, databasePath: String) -> RoutingSelection? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else { return nil }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT model, reasoning_effort FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, routingSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let modelPointer = sqlite3_column_text(statement, 0),
              let effortPointer = sqlite3_column_text(statement, 1)
        else { return nil }
        return RoutingSelection(
            model: String(cString: modelPointer),
            reasoningEffort: String(cString: effortPointer))
    }

    public static func isTopLevelUserTask(sessionID: String, databasePath: String) -> Bool {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else { return false }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT source, thread_source, archived FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, routingSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        let source = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
        let threadSource = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        let archived = sqlite3_column_int(statement, 2) != 0
        return !archived &&
            threadSource.caseInsensitiveCompare("subagent") != .orderedSame &&
            !source.localizedCaseInsensitiveContains("\"subagent\"")
    }
}

public enum CodexRolloutPreflightReader {
    public static let maximumHeadBytes = 512 * 1_024
    public static let maximumTailBytes: UInt64 = 512 * 1_024

    /// Reads only routing identity and the latest turn configuration. Prompt,
    /// instructions, tool content, and model output are never returned.
    public static func read(sessionID: String, transcriptPath: String) -> CodexRolloutPreflightFacts? {
        let url = URL(fileURLWithPath: transcriptPath)
        guard let headHandle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? headHandle.close() }
        guard let head = try? headHandle.read(upToCount: maximumHeadBytes),
              let firstLine = head.split(separator: 0x0A, omittingEmptySubsequences: true).first,
              let firstObject = try? JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              firstObject["type"] as? String == "session_meta",
              let metadata = firstObject["payload"] as? [String: Any]
        else { return nil }
        let metadataSessionID = (metadata["session_id"] as? String) ?? (metadata["id"] as? String)
        guard metadataSessionID == sessionID else { return nil }
        let threadSource = (metadata["thread_source"] as? String) ?? ""
        let source = (metadata["source"] as? String) ?? ""
        let isTopLevel = threadSource.caseInsensitiveCompare("user") == .orderedSame &&
            !source.localizedCaseInsensitiveContains("subagent")

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let tailHandle = try? FileHandle(forReadingFrom: url)
        else {
            return CodexRolloutPreflightFacts(isTopLevelUserTask: isTopLevel, selection: nil)
        }
        defer { try? tailHandle.close() }
        let start = size > maximumTailBytes ? size - maximumTailBytes : 0
        try? tailHandle.seek(toOffset: start)
        guard var tail = try? tailHandle.readToEnd() else {
            return CodexRolloutPreflightFacts(isTopLevelUserTask: isTopLevel, selection: nil)
        }
        if start > 0, let newline = tail.firstIndex(of: 0x0A) {
            tail = Data(tail.suffix(from: tail.index(after: newline)))
        }
        var selection: RoutingSelection?
        for line in tail.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "turn_context",
                  let payload = object["payload"] as? [String: Any],
                  let model = payload["model"] as? String,
                  let effort = payload["effort"] as? String,
                  !model.isEmpty,
                  !effort.isEmpty
            else { continue }
            selection = RoutingSelection(model: model, reasoningEffort: effort)
        }
        return CodexRolloutPreflightFacts(isTopLevelUserTask: isTopLevel, selection: selection)
    }
}

public enum RoutingReplaySafety {
    public static let maximumTailBytes: UInt64 = 512 * 1_024

    public enum LifecycleState: String, Equatable, Sendable {
        case notStarted
        case active
        case idle
        case unknown
    }

    public static func lifecycleState(transcriptPath: String) -> LifecycleState {
        let url = URL(fileURLWithPath: transcriptPath)
        guard let handle = try? FileHandle(forReadingFrom: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcriptPath),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return .unknown }
        defer { try? handle.close() }
        let start = size > maximumTailBytes ? size - maximumTailBytes : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return .unknown }
        if start > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data.suffix(from: data.index(after: newline)))
        }
        var sawSessionMeta = false
        var state: LifecycleState?
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            if type == "session_meta" {
                sawSessionMeta = true
                continue
            }
            guard type == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let event = payload["type"] as? String
            else { continue }
            if event == "task_started" {
                state = .active
            } else if ["task_complete", "task_failed", "turn_failed", "turn_aborted"].contains(event) {
                state = .idle
            }
        }
        if let state { return state }
        // A fresh top-level task has a valid session_meta line before its first
        // provider call, but no lifecycle event yet. That is safe to block and
        // replay; a truncated/corrupt tail without session metadata is not.
        return sawSessionMeta && start == 0 ? .notStarted : .unknown
    }

    /// Returns nil when the private rollout cannot be read or its bounded tail
    /// does not establish a lifecycle state. Callers must fail closed and must
    /// not offer replay in that case.
    public static func isTurnActive(transcriptPath: String) -> Bool? {
        switch lifecycleState(transcriptPath: transcriptPath) {
        case .active: return true
        case .idle, .notStarted: return false
        case .unknown: return nil
        }
    }

    public static func canReplay(sessionID: String, databasePath: String) -> Bool {
        guard CodexThreadSelectionReader.isTopLevelUserTask(
            sessionID: sessionID,
            databasePath: databasePath)
        else { return false }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database
        else { return false }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, sessionID, -1, routingSQLiteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let path = sqlite3_column_text(statement, 0).map({ String(cString: $0) })
        else { return false }
        return isTurnActive(transcriptPath: path) == false
    }
}

public enum RoutingHookInstaller {
    public static func install(command: String, hooksFile: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        let existingData = try Data(contentsOf: hooksFile)
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw NSError(domain: "RoutingHookInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "hooks.json 顶层不是对象"])
        }
        let nestedSchema = root["hooks"] is [String: Any]
        var events = (root["hooks"] as? [String: Any]) ?? root
        var matchers = events["UserPromptSubmit"] as? [[String: Any]] ?? []
        let marker = "--user-prompt-submit-hook"
        let alreadyInstalled = matchers.contains { matcher in
            (matcher["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains(marker) == true
            } == true
        }
        if alreadyInstalled { return nil }

        matchers.append(["hooks": [[
            "command": "'\(command.replacingOccurrences(of: "'", with: "'\\''"))' \(marker)",
            "type": "command",
            "timeout": 15,
        ]]])
        events["UserPromptSubmit"] = matchers
        if nestedSchema {
            root["hooks"] = events
        } else {
            root = events
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = hooksFile.deletingLastPathComponent().appendingPathComponent(
            "\(hooksFile.lastPathComponent).guardian-backup-\(formatter.string(from: now))")
        try manager.copyItem(at: hooksFile, to: backup)
        let output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: hooksFile, options: .atomic)
        return backup
    }
}
