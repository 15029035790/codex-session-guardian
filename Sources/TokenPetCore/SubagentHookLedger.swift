import Foundation

public enum SubagentHookEvent: String, Codable, Equatable, Sendable {
    case start = "SubagentStart"
    case stop = "SubagentStop"
    case unknown
}

public enum SubagentHookOutcome: String, Codable, Equatable, Sendable {
    case parsed
    case failed
}

public enum SubagentHookHealthState: String, Codable, Equatable, Sendable {
    case notInstalled = "not_installed"
    case installedButUntrusted = "installed_but_untrusted"
    case awaitingFirstEvent = "awaiting_first_event"
    case healthy
    case stale
}

/// Health reasons are intentionally separate from the state. In particular,
/// an empty lifecycle ledger is not the same as an untrusted or inactive Hook.
public enum SubagentHookHealthReason: String, Codable, Equatable, Sendable {
    case hookNotInstalled = "hook_not_installed"
    case hookUntrusted = "hook_untrusted"
    case noSubagentActivity = "no_subagent_activity"
    case hookInactive = "hook_inactive"
    case recentLifecycleEvent = "recent_lifecycle_event"
}

public struct CodexHookMetadata: Codable, Equatable, Sendable {
    public var key: String?
    public var eventName: String?
    public var command: String?
    public var sourcePath: String?
    public var enabled: Bool?
    public var currentHash: String?
    public var trustStatus: String?

    public init(
        key: String? = nil,
        eventName: String? = nil,
        command: String? = nil,
        sourcePath: String? = nil,
        enabled: Bool? = nil,
        currentHash: String? = nil,
        trustStatus: String? = nil
    ) {
        self.key = key
        self.eventName = eventName
        self.command = command
        self.sourcePath = sourcePath
        self.enabled = enabled
        self.currentHash = currentHash
        self.trustStatus = trustStatus
    }
}

public struct SubagentHookConfiguration: Codable, Equatable, Sendable {
    public var event: SubagentHookEvent
    public var installed: Bool
    public var enabled: Bool
    public var trusted: Bool
    public var trustStatus: String?
    public var command: String?
    public var currentHash: String?
    public var configSectionFound: Bool
    /// The most recent local trust/config change. Rollout activity from before
    /// this point cannot prove that a newly trusted Hook failed to run.
    public var trustConfiguredAt: Date?
    public var inspectedAt: Date

    public init(
        event: SubagentHookEvent,
        installed: Bool,
        enabled: Bool,
        trusted: Bool,
        trustStatus: String?,
        command: String?,
        currentHash: String?,
        configSectionFound: Bool,
        trustConfiguredAt: Date? = nil,
        inspectedAt: Date = Date()
    ) {
        self.event = event
        self.installed = installed
        self.enabled = enabled
        self.trusted = trusted
        self.trustStatus = trustStatus
        self.command = command
        self.currentHash = currentHash
        self.configSectionFound = configSectionFound
        self.trustConfiguredAt = trustConfiguredAt
        self.inspectedAt = inspectedAt
    }
}

public struct SubagentHookHealth: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let lifecycleDeliveryGraceInterval: TimeInterval = 60

    public var schemaVersion: Int
    public var event: SubagentHookEvent
    public var state: SubagentHookHealthState
    public var reason: SubagentHookHealthReason
    public var installed: Bool
    public var trusted: Bool
    /// Non-nil when Codex `hooks/list` supplied the authoritative status.
    /// Nil means the local config fallback was used.
    public var trustStatus: String?
    public var latestObservationAt: Date?
    public var latestSubagentActivityAt: Date?
    public var observedAt: Date

    public init(
        event: SubagentHookEvent,
        state: SubagentHookHealthState,
        reason: SubagentHookHealthReason,
        installed: Bool,
        trusted: Bool,
        trustStatus: String? = nil,
        latestObservationAt: Date?,
        latestSubagentActivityAt: Date?,
        observedAt: Date = Date(),
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.event = event
        self.state = state
        self.reason = reason
        self.installed = installed
        self.trusted = trusted
        self.trustStatus = trustStatus
        self.latestObservationAt = latestObservationAt
        self.latestSubagentActivityAt = latestSubagentActivityAt
        self.observedAt = observedAt
    }

    public static func evaluate(
        configuration: SubagentHookConfiguration,
        latestObservationAt: Date?,
        latestSubagentActivityAt: Date?,
        now: Date = Date()
    ) -> Self {
        let state: SubagentHookHealthState
        let reason: SubagentHookHealthReason
        if !configuration.installed || !configuration.enabled {
            state = .notInstalled
            reason = .hookNotInstalled
        } else if !configuration.trusted {
            state = .installedButUntrusted
            reason = .hookUntrusted
        } else if let latestSubagentActivityAt,
                  latestSubagentActivityAt >= (configuration.trustConfiguredAt ?? .distantPast),
                  latestObservationAt?.addingTimeInterval(lifecycleDeliveryGraceInterval) ?? .distantPast < latestSubagentActivityAt {
            // A newer lifecycle event was expected, but this Hook did not
            // reach Guardian. A completed child does not require heartbeats,
            // so elapsed time alone must not make an old valid event stale.
            state = .stale
            reason = .hookInactive
        } else if latestObservationAt != nil {
            state = .healthy
            reason = .recentLifecycleEvent
        } else {
            state = .awaitingFirstEvent
            reason = .noSubagentActivity
        }
        return Self(
            event: configuration.event,
            state: state,
            reason: reason,
            installed: configuration.installed,
            trusted: configuration.trusted,
            trustStatus: configuration.trustStatus,
            latestObservationAt: latestObservationAt,
            latestSubagentActivityAt: latestSubagentActivityAt,
            observedAt: now)
    }
}

public struct SubagentHookHealthSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var start: SubagentHookHealth
    public var stop: SubagentHookHealth
    public var subagentActivityCount: Int
    public var observedAt: Date

    public init(
        start: SubagentHookHealth,
        stop: SubagentHookHealth,
        subagentActivityCount: Int,
        observedAt: Date = Date(),
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.start = start
        self.stop = stop
        self.subagentActivityCount = max(0, subagentActivityCount)
        self.observedAt = observedAt
    }

    public var requiresAttention: Bool {
        let startNeedsAttention = start.state == .installedButUntrusted ||
            start.state == .stale || start.state == .notInstalled
        let stopNeedsAttention = stop.state == .installedButUntrusted ||
            stop.state == .stale || stop.state == .notInstalled
        return startNeedsAttention || stopNeedsAttention
    }
}

/// Acknowledges one unchanged lifecycle-health state. A newly unhealthy state
/// has a different fingerprint and becomes visible again.
public struct SubagentHookHealthReminderSuppression: Equatable, Sendable {
    public private(set) var dismissedFingerprint: String?

    public init(dismissedFingerprint: String? = nil) {
        self.dismissedFingerprint = dismissedFingerprint
    }

    public func suppresses(_ snapshot: SubagentHookHealthSnapshot) -> Bool {
        dismissedFingerprint == Self.fingerprint(for: snapshot)
    }

    public mutating func dismiss(_ snapshot: SubagentHookHealthSnapshot) {
        dismissedFingerprint = Self.fingerprint(for: snapshot)
    }

    public mutating func reconcile(with snapshot: SubagentHookHealthSnapshot) {
        if dismissedFingerprint != Self.fingerprint(for: snapshot) {
            dismissedFingerprint = nil
        }
    }

    public static func fingerprint(for snapshot: SubagentHookHealthSnapshot) -> String {
        [
            snapshot.start.state.rawValue,
            snapshot.start.reason.rawValue,
            snapshot.stop.state.rawValue,
            snapshot.stop.reason.rawValue,
        ].joined(separator: ":")
    }
}

public struct SubagentHookHealthDiagnostic: Codable, Equatable, Sendable {
    public var id: String
    public var observedAt: Date
    public var snapshot: SubagentHookHealthSnapshot

    public init(
        id: String = UUID().uuidString,
        observedAt: Date = Date(),
        snapshot: SubagentHookHealthSnapshot
    ) {
        self.id = id
        self.observedAt = observedAt
        self.snapshot = snapshot
    }
}

public enum SubagentHookConfigurationInspector {
    public static func inspect(
        hooksFile: URL,
        configFile: URL? = nil,
        appServerHooks: [CodexHookMetadata] = [],
        now: Date = Date()
    ) -> [SubagentHookConfiguration] {
        let hooks = loadHooks(from: hooksFile)
        let trustedHashes = loadTrustedHashes(from: configFile)
        let trustConfiguredAt = configFile.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return [SubagentHookEvent.start, .stop].map { event in
            inspect(
                event: event,
                hooks: hooks,
                trustedHashes: trustedHashes,
                appServerHooks: appServerHooks,
                hooksFilename: hooksFile.lastPathComponent,
                trustConfiguredAt: trustConfiguredAt,
                now: now)
        }
    }

    private static func inspect(
        event: SubagentHookEvent,
        hooks: [String: Any]?,
        trustedHashes: [String: String],
        appServerHooks: [CodexHookMetadata],
        hooksFilename: String,
        trustConfiguredAt: Date?,
        now: Date
    ) -> SubagentHookConfiguration {
        let key = event.rawValue.lowercased()
            .replacingOccurrences(of: "subagentstart", with: "subagent_start")
            .replacingOccurrences(of: "subagentstop", with: "subagent_stop")
        var command: String?
        var installed = false
        var enabled = true
        var matcherIndex = 0
        var hookIndex = 0

        if let matchers = hooks?[event.rawValue] as? [[String: Any]] {
            for (candidateMatcherIndex, matcher) in matchers.enumerated() {
                guard let candidateHooks = matcher["hooks"] as? [[String: Any]] else { continue }
                if let candidateHookIndex = candidateHooks.firstIndex(where: {
                    ($0["command"] as? String)?.contains("--subagent-lifecycle-hook") == true
                }), let candidateCommand = candidateHooks[candidateHookIndex]["command"] as? String {
                    installed = true
                    command = candidateCommand
                    matcherIndex = candidateMatcherIndex
                    hookIndex = candidateHookIndex
                    enabled = candidateHooks[candidateHookIndex]["enabled"] as? Bool ?? true
                    break
                }
            }
        }

        let expectedKey = "\(hooksFilename):\(key):\(matcherIndex):\(hookIndex)"
        let matchingMetadata = appServerHooks.first { metadata in
            let eventMatches = canonicalEventName(metadata.eventName) == key
            let keyMatches = metadata.key == expectedKey || metadata.key?.hasSuffix(":\(key):\(matcherIndex):\(hookIndex)") == true
            let commandMatches = command != nil && metadata.command == command
            return eventMatches && (keyMatches || commandMatches || metadata.key == nil)
        }
        if let metadata = matchingMetadata {
            installed = installed || metadata.command != nil || metadata.key != nil
            enabled = metadata.enabled ?? enabled
            command = metadata.command ?? command
        }

        let configKey = trustedHashes.keys.first { candidate in
            candidate == expectedKey || candidate.hasSuffix(":\(key):\(matcherIndex):\(hookIndex)")
        }
        let configSectionFound = configKey != nil
        let configTrusted = configKey != nil && !(trustedHashes[configKey!] ?? "").isEmpty
        let trustStatus = matchingMetadata?.trustStatus.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedTrust = trustStatus?.lowercased()
        let trusted: Bool
        if let normalizedTrust, !normalizedTrust.isEmpty {
            trusted = normalizedTrust == "trusted"
        } else {
            trusted = configTrusted
        }

        return SubagentHookConfiguration(
            event: event,
            installed: installed,
            enabled: enabled,
            trusted: trusted,
            trustStatus: trustStatus,
            command: command,
            currentHash: matchingMetadata?.currentHash,
            configSectionFound: configSectionFound,
            trustConfiguredAt: trustConfiguredAt,
            inspectedAt: now)
    }

    private static func loadHooks(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return root["hooks"] as? [String: Any] ?? root
    }

    private static func loadTrustedHashes(from url: URL?) -> [String: String] {
        guard let url,
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var current: String?
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[hooks.state.\""), line.hasSuffix("\"]") {
                let prefix = "[hooks.state.\""
                current = String(line.dropFirst(prefix.count).dropLast(2))
                continue
            }
            if line.hasPrefix("[") {
                current = nil
                continue
            }
            guard let current,
                  line.hasPrefix("trusted_hash") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let rawValue = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            result[current] = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }

    private static func canonicalEventName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
        if normalized == "subagentstart" { return "subagent_start" }
        if normalized == "subagentstop" { return "subagent_stop" }
        return normalized
    }
}

/// Privacy-safe evidence from one Codex subagent lifecycle Hook invocation.
/// It never stores cwd, transcript paths, prompts, assistant messages, tool
/// payloads, or raw identifiers.
public struct SubagentHookObservation: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: String
    public var observedAt: Date
    public var event: SubagentHookEvent
    public var outcome: SubagentHookOutcome
    public var reasonCode: String
    public var sessionHash: String?
    public var turnHash: String?
    public var agentHash: String?
    public var agentType: String?
    public var model: String?
    public var permissionMode: String?
    public var forkTurns: String?
    public var hasTranscriptPath: Bool
    public var hasAgentTranscriptPath: Bool
    public var stopHookActive: Bool?
    public var inputKeys: [String]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        id: String = UUID().uuidString,
        observedAt: Date = Date(),
        event: SubagentHookEvent,
        outcome: SubagentHookOutcome,
        reasonCode: String,
        sessionHash: String?,
        turnHash: String?,
        agentHash: String?,
        agentType: String?,
        model: String?,
        permissionMode: String?,
        forkTurns: String?,
        hasTranscriptPath: Bool,
        hasAgentTranscriptPath: Bool,
        stopHookActive: Bool?,
        inputKeys: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.observedAt = observedAt
        self.event = event
        self.outcome = outcome
        self.reasonCode = reasonCode
        self.sessionHash = sessionHash
        self.turnHash = turnHash
        self.agentHash = agentHash
        self.agentType = agentType
        self.model = model
        self.permissionMode = permissionMode
        self.forkTurns = forkTurns
        self.hasTranscriptPath = hasTranscriptPath
        self.hasAgentTranscriptPath = hasAgentTranscriptPath
        self.stopHookActive = stopHookActive
        self.inputKeys = inputKeys.sorted()
    }

    public static func parse(_ data: Data, now: Date = Date()) -> Self {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Self(
                observedAt: now,
                event: .unknown,
                outcome: .failed,
                reasonCode: "invalid_json",
                sessionHash: nil,
                turnHash: nil,
                agentHash: nil,
                agentType: nil,
                model: nil,
                permissionMode: nil,
                forkTurns: nil,
                hasTranscriptPath: false,
                hasAgentTranscriptPath: false,
                stopHookActive: nil,
                inputKeys: [])
        }

        let event = switch object["hook_event_name"] as? String {
        case SubagentHookEvent.start.rawValue: SubagentHookEvent.start
        case SubagentHookEvent.stop.rawValue: SubagentHookEvent.stop
        default: SubagentHookEvent.unknown
        }
        let sessionID = nonEmptyString(object["session_id"])
        let turnID = nonEmptyString(object["turn_id"])
        let agentID = nonEmptyString(object["agent_id"])
        let agentType = safeLabel(object["agent_type"], maximumLength: 80)
        let model = safeLabel(object["model"], maximumLength: 120)
        let permissionMode = safeLabel(object["permission_mode"], maximumLength: 40)
        let forkTurns = safeForkTurns(object["fork_turns"])
        let hasRequiredFields = event != .unknown && sessionID != nil && turnID != nil &&
            agentID != nil && agentType != nil && model != nil

        return Self(
            observedAt: now,
            event: event,
            outcome: hasRequiredFields ? .parsed : .failed,
            reasonCode: hasRequiredFields ? "lifecycle_event_recorded" :
                (event == .unknown ? "unsupported_event" : "required_fields_missing"),
            sessionHash: sessionID.map(RoutingPreflightObservation.opaqueHash),
            turnHash: turnID.map(RoutingPreflightObservation.opaqueHash),
            agentHash: agentID.map(RoutingPreflightObservation.opaqueHash),
            agentType: agentType,
            model: model,
            permissionMode: permissionMode,
            forkTurns: forkTurns,
            hasTranscriptPath: nonEmptyString(object["transcript_path"]) != nil,
            hasAgentTranscriptPath: nonEmptyString(object["agent_transcript_path"]) != nil,
            stopHookActive: object["stop_hook_active"] as? Bool,
            inputKeys: object.keys.sorted())
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func safeLabel(_ value: Any?, maximumLength: Int) -> String? {
        guard let value = nonEmptyString(value) else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/"))
        guard value.unicodeScalars.allSatisfy(allowed.contains) else { return "other" }
        return String(value.prefix(maximumLength))
    }

    private static func safeForkTurns(_ value: Any?) -> String? {
        guard let value = nonEmptyString(value)?.lowercased() else { return nil }
        if value == "all" || value == "none" { return value }
        if let count = Int(value), count >= 0 { return String(count) }
        return "other"
    }
}

public enum SubagentObservationHookInstaller {
    public static func install(command: String, hooksFile: URL, now: Date = Date()) throws -> URL? {
        let manager = FileManager.default
        let existingData = try Data(contentsOf: hooksFile)
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw NSError(
                domain: "SubagentObservationHookInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "hooks.json 顶层不是对象"])
        }
        let nestedSchema = root["hooks"] is [String: Any]
        var events = (root["hooks"] as? [String: Any]) ?? root
        let marker = "--subagent-lifecycle-hook"
        let escapedCommand = command.replacingOccurrences(of: "'", with: "'\\''")
        var changed = false

        for eventName in [SubagentHookEvent.start.rawValue, SubagentHookEvent.stop.rawValue] {
            var matchers = events[eventName] as? [[String: Any]] ?? []
            let installed = matchers.contains { matcher in
                (matcher["hooks"] as? [[String: Any]])?.contains {
                    ($0["command"] as? String)?.contains(marker) == true
                } == true
            }
            guard !installed else { continue }
            matchers.append(["hooks": [[
                "command": "'\(escapedCommand)' \(marker)",
                "type": "command",
                "timeout": 5,
            ]]])
            events[eventName] = matchers
            changed = true
        }
        guard changed else { return nil }

        if nestedSchema { root["hooks"] = events } else { root = events }
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
