import CryptoKit
import Foundation

public enum ExecutionWasteReason: String, Codable, CaseIterable, Equatable, Sendable {
    case repeatedRead = "repeated_read"
    case retryWithoutChange = "retry_without_change"
    case outputBloat = "output_bloat"
}

public enum ExecutionWasteEvidenceCode: String, Codable, Equatable, Sendable {
    case exactReadRepeatedWithoutProgress = "exact_read_repeated_without_progress"
    case exactRetryAfterExplicitFailure = "exact_retry_after_explicit_failure"
    case singleOutputThresholdExceeded = "single_output_threshold_exceeded"
    case cumulativeOutputThresholdExceeded = "cumulative_output_threshold_exceeded"
}

/// An anonymous review trace. Operation inputs are represented only by their
/// SHA-256 fingerprint; event positions and measured bytes contain no content.
public struct ExecutionWasteOccurrence: Codable, Equatable, Sendable {
    public var reason: ExecutionWasteReason
    public var evidenceCode: ExecutionWasteEvidenceCode
    public var operationHash: String?
    public var generation: Int
    public var actionOrdinal: Int
    public var previousActionOrdinal: Int?
    public var measuredBytes: Int?
    public var cumulativeBytes: Int?
}

public struct ExecutionWasteProfile: Codable, Equatable, Sendable {
    public var repeatedReadCount = 0
    public var unchangedRetryCount = 0
    public var bloatedOutputCount = 0
    public var totalToolOutputBytes = 0
    public var largestToolOutputBytes = 0
    public var bloatedOutputBytes = 0
    public var occurrences: [ExecutionWasteOccurrence]?

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
    public static let currentSchemaVersion = 2
    public static let currentPolicyVersion = "execution-waste-v1.2"

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
    public var occurrences: [ExecutionWasteOccurrence]?
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
            occurrences: profile.occurrences,
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
    private static let maximumReviewOccurrences = 64

    private enum OperationKind: String, Codable, Equatable, Sendable {
        case read
        case other
    }

    private struct PendingOperation: Codable, Equatable, Sendable {
        var fingerprint: String
        var kind: OperationKind?
        var generation: Int
        var actionOrdinal: Int
    }

    private struct SeenOperation: Codable, Equatable, Sendable {
        var generation: Int
        var actionOrdinal: Int
    }

    private struct ReadResult: Codable, Equatable, Sendable {
        var generation: Int
        var actionOrdinal: Int
        var outputHash: String?
    }

    private struct OutputAccumulator: Codable, Equatable, Sendable {
        var generation: Int
        var bytes: Int
        var flagged: Bool
        var firstActionOrdinal: Int
    }

    var profile = ExecutionWasteProfile()
    private var generation = 0
    private var actionOrdinal = 0
    private var pending: [String: PendingOperation] = [:]
    private var seenReads: [String: ReadResult] = [:]
    private var readOrder: [String] = []
    private var failures: [String: SeenOperation] = [:]
    private var failureOrder: [String] = []
    private var outputByOperation: [String: OutputAccumulator] = [:]
    private var outputOrder: [String] = []

    mutating func recordToolCall(name rawName: String, payload: [String: Any]) {
        actionOrdinal += 1
        let normalized = Self.normalizedOperation(name: rawName, payload: payload)
        let fingerprint = Self.digest(normalized.identity)
        if let failure = failures[fingerprint], failure.generation == generation {
            profile.unchangedRetryCount += 1
            appendOccurrence(.init(
                reason: .retryWithoutChange,
                evidenceCode: .exactRetryAfterExplicitFailure,
                operationHash: fingerprint,
                generation: generation,
                actionOrdinal: actionOrdinal,
                previousActionOrdinal: failure.actionOrdinal,
                measuredBytes: nil,
                cumulativeBytes: nil))
        }
        guard let callID = payload["call_id"] as? String, !callID.isEmpty else { return }
        pending[callID] = PendingOperation(
            fingerprint: fingerprint,
            kind: normalized.kind,
            generation: generation,
            actionOrdinal: actionOrdinal)
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
            appendOccurrence(.init(
                reason: .outputBloat,
                evidenceCode: .singleOutputThresholdExceeded,
                operationHash: operation?.fingerprint,
                generation: generation,
                actionOrdinal: operation?.actionOrdinal ?? actionOrdinal,
                previousActionOrdinal: nil,
                measuredBytes: bytes,
                cumulativeBytes: bytes))
        }
        if let operation {
            if operation.kind == .read, disposition != .failure {
                let outputHash = Self.outputFingerprint(raw)
                if let previous = seenReads[operation.fingerprint],
                   previous.generation == operation.generation,
                   previous.outputHash == outputHash
                {
                    profile.repeatedReadCount += 1
                    appendOccurrence(.init(
                        reason: .repeatedRead,
                        evidenceCode: .exactReadRepeatedWithoutProgress,
                        operationHash: operation.fingerprint,
                        generation: operation.generation,
                        actionOrdinal: operation.actionOrdinal,
                        previousActionOrdinal: previous.actionOrdinal,
                        measuredBytes: bytes,
                        cumulativeBytes: nil))
                }
                seenReads[operation.fingerprint] = ReadResult(
                    generation: operation.generation,
                    actionOrdinal: operation.actionOrdinal,
                    outputHash: outputHash)
                Self.appendBounded(
                    operation.fingerprint,
                    to: &readOrder,
                    dictionary: &seenReads)
            }
            var accumulated = outputByOperation[operation.fingerprint]
            if accumulated?.generation != generation {
                accumulated = OutputAccumulator(
                    generation: generation,
                    bytes: 0,
                    flagged: false,
                    firstActionOrdinal: operation.actionOrdinal)
            }
            accumulated!.bytes += bytes
            if bytes < Self.singleOutputBloatBytes,
               accumulated!.bytes >= Self.repeatedOutputBloatBytes,
               !accumulated!.flagged
            {
                accumulated!.flagged = true
                profile.bloatedOutputCount += 1
                profile.bloatedOutputBytes += accumulated!.bytes
                appendOccurrence(.init(
                    reason: .outputBloat,
                    evidenceCode: .cumulativeOutputThresholdExceeded,
                    operationHash: operation.fingerprint,
                    generation: generation,
                    actionOrdinal: operation.actionOrdinal,
                    previousActionOrdinal: accumulated!.firstActionOrdinal,
                    measuredBytes: bytes,
                    cumulativeBytes: accumulated!.bytes))
            } else if bytes >= Self.singleOutputBloatBytes {
                accumulated!.flagged = true
            }
            outputByOperation[operation.fingerprint] = accumulated
            Self.appendBounded(
                operation.fingerprint,
                to: &outputOrder,
                dictionary: &outputByOperation)
            if disposition == .failure {
                failures[operation.fingerprint] = SeenOperation(
                    generation: operation.generation,
                    actionOrdinal: operation.actionOrdinal)
                Self.appendBounded(
                    operation.fingerprint,
                    to: &failureOrder,
                    dictionary: &failures)
            } else if disposition == .success {
                failures.removeValue(forKey: operation.fingerprint)
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

    private mutating func appendOccurrence(_ occurrence: ExecutionWasteOccurrence) {
        var occurrences = profile.occurrences ?? []
        occurrences.append(occurrence)
        if occurrences.count > Self.maximumReviewOccurrences {
            occurrences.removeFirst(occurrences.count - Self.maximumReviewOccurrences)
        }
        profile.occurrences = occurrences
    }

    private static func normalizedOperation(
        name rawName: String,
        payload: [String: Any]
    ) -> (identity: String, kind: OperationKind) {
        let name = rawName.lowercased()
        let rawInput = operationInput(payload)
        let command = extractExecCommand(from: rawInput)
        let kind: OperationKind
        if isStaticReadTool(name) || command.map(isConservativeStaticReadCommand) == true {
            kind = .read
        } else {
            kind = .other
        }
        // Keep the complete structured input in the fingerprint. Execution
        // conditions such as sandbox escalation, cwd, and TTY are meaningful
        // changes even when the nested command text is identical.
        return ("\(name)|\(rawInput)", kind)
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

    private static func isStaticReadTool(_ name: String) -> Bool {
        let leaf = name.split(separator: "_").suffix(2).joined(separator: "_")
        return [
            "read", "read_file", "read_text", "view_file", "read_resource",
        ].contains(name) || ["read_file", "read_text", "view_file", "read_resource"].contains(leaf)
    }

    private static func isConservativeStaticReadCommand(_ command: String) -> Bool {
        let value = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !value.isEmpty,
              !["\n", "&&", "||", ";", "|", ">", "<"].contains(where: value.contains)
        else { return false }
        return [
            "rg ", "sed -n ", "cat ", "head ", "tail ", "wc ", "shasum ",
            "plutil -p ", "git show ", "git log ",
        ].contains(where: value.hasPrefix)
    }

    private static func outputFingerprint(_ raw: Any?) -> String {
        if let value = raw as? String { return digest(value) }
        if let blocks = raw as? [[String: Any]] {
            let texts = blocks.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return digest(texts.joined(separator: "\n")) }
        }
        if let dictionary = raw as? [String: Any] {
            if let output = dictionary["output"] { return outputFingerprint(output) }
            if let text = dictionary["text"] { return outputFingerprint(text) }
            if let content = dictionary["content"] { return outputFingerprint(content) }
        }
        if let raw, JSONSerialization.isValidJSONObject(raw),
           let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
        {
            return digest(String(decoding: data, as: UTF8.self))
        }
        return digest("")
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
