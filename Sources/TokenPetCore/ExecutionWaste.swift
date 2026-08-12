import CryptoKit
import Foundation

public enum ExecutionWasteReason: String, Codable, CaseIterable, Equatable, Sendable {
    case repeatedRead = "repeated_read"
    case retryWithoutChange = "retry_without_change"
    case outputBloat = "output_bloat"
}

public struct ExecutionWasteProfile: Codable, Equatable, Sendable {
    public var repeatedReadCount = 0
    public var unchangedRetryCount = 0
    public var bloatedOutputCount = 0
    public var totalToolOutputBytes = 0
    public var largestToolOutputBytes = 0
    public var bloatedOutputBytes = 0

    public init() {}

    public var reasons: [ExecutionWasteReason] {
        var result: [ExecutionWasteReason] = []
        if repeatedReadCount > 0 { result.append(.repeatedRead) }
        if unchangedRetryCount > 0 { result.append(.retryWithoutChange) }
        if bloatedOutputCount > 0 { result.append(.outputBloat) }
        return result
    }
}

public struct ExecutionWasteEvidence: Codable, Equatable, Sendable {
    public var reason: ExecutionWasteReason
    public var occurrences: Int
    public var measuredBytes: Int?
}

/// A privacy-safe, terminal-turn shadow observation. It excludes session and
/// turn identifiers, paths, prompts, commands, tool arguments, and tool output.
public struct ExecutionWasteObservation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let currentPolicyVersion = "execution-waste-v1"

    public var schemaVersion: Int
    public var id: String
    public var observedAt: Date
    public var status: TurnStatus
    public var qualityEvidence: RoutingQualityEvidence
    public var calls: Int
    public var observedActions: Int
    public var usage: TokenUsage
    public var totalToolOutputBytes: Int
    public var largestToolOutputBytes: Int
    public var evidence: [ExecutionWasteEvidence]
    public var policyVersion: String

    public static func derive(from turn: TurnRecord) -> Self? {
        guard turn.status != .running else { return nil }
        let profile = turn.executionWasteProfile ?? ExecutionWasteProfile()
        let execution = turn.executionProfile
        let quality: RoutingQualityEvidence
        if turn.status == .interrupted {
            quality = .interrupted
        } else if (execution?.failureSignals ?? 0) > 0 {
            quality = .verifiedFailure
        } else if (execution?.verificationActions ?? 0) > 0 {
            quality = .verifiedSuccess
        } else {
            quality = .completedUnverified
        }
        var evidence: [ExecutionWasteEvidence] = []
        if profile.repeatedReadCount > 0 {
            evidence.append(.init(
                reason: .repeatedRead,
                occurrences: profile.repeatedReadCount,
                measuredBytes: nil))
        }
        if profile.unchangedRetryCount > 0 {
            evidence.append(.init(
                reason: .retryWithoutChange,
                occurrences: profile.unchangedRetryCount,
                measuredBytes: nil))
        }
        if profile.bloatedOutputCount > 0 {
            evidence.append(.init(
                reason: .outputBloat,
                occurrences: profile.bloatedOutputCount,
                measuredBytes: profile.bloatedOutputBytes))
        }
        return Self(
            schemaVersion: currentSchemaVersion,
            id: digest("\(turn.id)|\(currentPolicyVersion)"),
            observedAt: turn.completedAt ?? turn.lastActivityAt ?? turn.startedAt ?? .distantPast,
            status: turn.status,
            qualityEvidence: quality,
            calls: max(0, turn.calls),
            observedActions: max(0, execution?.observedActions ?? 0),
            usage: turn.usage,
            totalToolOutputBytes: max(0, profile.totalToolOutputBytes),
            largestToolOutputBytes: max(0, profile.largestToolOutputBytes),
            evidence: evidence,
            policyVersion: currentPolicyVersion)
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ExecutionWasteTracker: Codable, Equatable, Sendable {
    static let singleOutputBloatBytes = 64 * 1_024
    static let repeatedOutputBloatBytes = 96 * 1_024
    private static let maximumTrackedOperations = 128

    private enum OperationKind: String, Codable, Sendable {
        case read
        case other
    }

    private struct PendingOperation: Codable, Equatable, Sendable {
        var fingerprint: String
        var generation: Int
    }

    private struct OutputAccumulator: Codable, Equatable, Sendable {
        var generation: Int
        var bytes: Int
        var flagged: Bool
    }

    var profile = ExecutionWasteProfile()
    private var generation = 0
    private var pending: [String: PendingOperation] = [:]
    private var seenReadGeneration: [String: Int] = [:]
    private var readOrder: [String] = []
    private var failedGeneration: [String: Int] = [:]
    private var failureOrder: [String] = []
    private var outputByOperation: [String: OutputAccumulator] = [:]
    private var outputOrder: [String] = []

    mutating func recordToolCall(name rawName: String, payload: [String: Any]) {
        let normalized = Self.normalizedOperation(name: rawName, payload: payload)
        let fingerprint = Self.digest(normalized.identity)
        if normalized.kind == .read {
            if seenReadGeneration[fingerprint] == generation {
                profile.repeatedReadCount += 1
            } else {
                seenReadGeneration[fingerprint] = generation
                Self.appendBounded(
                    fingerprint,
                    to: &readOrder,
                    dictionary: &seenReadGeneration)
            }
        }
        if failedGeneration[fingerprint] == generation {
            profile.unchangedRetryCount += 1
        }
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else { return }
        pending[callID] = PendingOperation(
            fingerprint: fingerprint,
            generation: generation)
        if pending.count > Self.maximumTrackedOperations, let first = pending.keys.sorted().first {
            pending.removeValue(forKey: first)
        }
    }

    mutating func recordToolOutput(callID: String?, raw: Any?) -> ToolOutputDisposition {
        let bytes = Self.outputByteCount(raw)
        profile.totalToolOutputBytes += bytes
        profile.largestToolOutputBytes = max(profile.largestToolOutputBytes, bytes)
        let operation = callID.flatMap { pending.removeValue(forKey: $0) }
        var disposition = Self.outputDisposition(raw)
        if bytes >= Self.singleOutputBloatBytes {
            profile.bloatedOutputCount += 1
            profile.bloatedOutputBytes += bytes
        }
        if let operation {
            var accumulated = outputByOperation[operation.fingerprint]
            if accumulated?.generation != generation {
                accumulated = OutputAccumulator(generation: generation, bytes: 0, flagged: false)
            }
            accumulated!.bytes += bytes
            if bytes < Self.singleOutputBloatBytes,
               accumulated!.bytes >= Self.repeatedOutputBloatBytes,
               !accumulated!.flagged
            {
                accumulated!.flagged = true
                profile.bloatedOutputCount += 1
                profile.bloatedOutputBytes += accumulated!.bytes
            } else if bytes >= Self.singleOutputBloatBytes {
                accumulated!.flagged = true
            }
            outputByOperation[operation.fingerprint] = accumulated
            Self.appendBounded(
                operation.fingerprint,
                to: &outputOrder,
                dictionary: &outputByOperation)
            if disposition == .failure {
                failedGeneration[operation.fingerprint] = operation.generation
                Self.appendBounded(
                    operation.fingerprint,
                    to: &failureOrder,
                    dictionary: &failedGeneration)
            } else if disposition == .success {
                failedGeneration.removeValue(forKey: operation.fingerprint)
                failureOrder.removeAll { $0 == operation.fingerprint }
            }
        } else if disposition == .failure {
            // A failure without a matching structured call cannot support an
            // unchanged-retry claim, so keep the status local and conservative.
            disposition = .unknown
        }
        return disposition
    }

    mutating func markProgressBoundary() {
        generation += 1
    }

    private static func normalizedOperation(
        name rawName: String,
        payload: [String: Any]
    ) -> (identity: String, kind: OperationKind) {
        let name = rawName.lowercased()
        let rawInput = operationInput(payload)
        let command = extractExecCommand(from: rawInput)
        let identityInput = command ?? rawInput
        let liveKind = LiveActivityParser.kind(forToolNamed: name)
        let kind: OperationKind
        if liveKind == .readingFile || command.map(isConservativeReadCommand) == true {
            kind = .read
        } else {
            kind = .other
        }
        return ("\(name)|\(identityInput)", kind)
    }

    private static func operationInput(_ payload: [String: Any]) -> String {
        let rawValue = payload["arguments"] ?? payload["input"]
        if let value = rawValue as? String { return value }
        if let rawValue, JSONSerialization.isValidJSONObject(rawValue),
           let data = try? JSONSerialization.data(withJSONObject: rawValue, options: [.sortedKeys])
        {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    private static func extractExecCommand(from raw: String) -> String? {
        guard raw.contains("exec_command") else { return nil }
        let pattern = #"(?:\"cmd\"|\bcmd)\s*:\s*(\"(?:\\.|[^\"\\])*\")"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..., in: raw)),
              let range = Range(match.range(at: 1), in: raw),
              let data = "[\(raw[range])]".data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return nil }
        return decoded.first
    }

    private static func isConservativeReadCommand(_ command: String) -> Bool {
        let value = command.lowercased()
        let mutatingOrExecuting = [
            "apply_patch", "git add", "git commit", "git push", "swift build", "swift test",
            "codex-session-guardian-tests", "npm ", "pnpm ", "yarn ", "cargo ", "go test",
            "pytest", "xcodebuild", "mkdir ", "cp ", "mv ", "rm ", "ditto ", ">",
        ]
        guard !mutatingOrExecuting.contains(where: value.contains) else { return false }
        return [
            "rg ", "sed -n", "git status", "git diff", "git log", "git show", "find ",
            "ls ", "head ", "tail ", "wc ", "stat ", "plutil -p", "jq ", "shasum ",
        ].contains(where: value.contains)
    }

    private static func outputByteCount(_ raw: Any?) -> Int {
        if let value = raw as? String { return value.utf8.count }
        if let blocks = raw as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            if !texts.isEmpty {
                return texts.reduce(0) { $0 + $1.utf8.count } + max(0, texts.count - 1)
            }
        }
        if let dictionary = raw as? [String: Any] {
            if let output = dictionary["output"] as? String { return output.utf8.count }
            if let text = dictionary["text"] as? String { return text.utf8.count }
            if let content = dictionary["content"] { return outputByteCount(content) }
        }
        if let value = raw, JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        {
            return data.count
        }
        return 0
    }

    private static func outputDisposition(_ raw: Any?) -> ToolOutputDisposition {
        let output: String
        if let text = raw as? String {
            output = text
        } else if let blocks = raw as? [[String: Any]] {
            output = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            return .unknown
        }
        if output.contains("Process exited with code 0") ||
            output.range(of: #"\"exit_code\"\s*:\s*0"#, options: .regularExpression) != nil ||
            output.range(of: #"exit_code\s*[:=]\s*0"#, options: .regularExpression) != nil {
            return .success
        }
        if output.range(of: #"Process exited with code [1-9][0-9]*"#, options: .regularExpression) != nil ||
            output.range(of: #"\"exit_code\"\s*:\s*-?[1-9][0-9]*"#, options: .regularExpression) != nil ||
            output.range(of: #"exit_code\s*[:=]\s*-?[1-9][0-9]*"#, options: .regularExpression) != nil {
            return .failure
        }
        return .unknown
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func appendBounded<Value>(
        _ key: String,
        to order: inout [String],
        dictionary: inout [String: Value]
    ) {
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maximumTrackedOperations {
            dictionary.removeValue(forKey: order.removeFirst())
        }
    }
}

enum ToolOutputDisposition: Equatable, Sendable {
    case success
    case failure
    case unknown
}
