import Foundation
import TokenPetCore

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let environment = ProcessInfo.processInfo.environment

private func routingHookEnvelope(_ data: Data) -> (sessionID: String?, keys: [String]) {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return (nil, [])
    }
    return (object["session_id"] as? String, object.keys.sorted())
}

private func recordRoutingHookDiagnostic(
    store: SQLiteStore?,
    sessionID: String?,
    outcome: RoutingHookDiagnosticOutcome,
    reasonCode: String,
    inputKeys: [String]
) {
    try? store?.recordRoutingHookDiagnostic(RoutingHookDiagnostic(
        sessionID: sessionID,
        outcome: outcome,
        reasonCode: reasonCode,
        inputKeys: inputKeys))
}

if arguments.contains("--subagent-lifecycle-hook") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let observation = SubagentHookObservation.parse(data)
    let guardianDatabase = option("--db") ?? SessionScanner.defaultDatabasePath(environment: environment)
    if let store = try? SQLiteStore(path: guardianDatabase) {
        try? store.recordSubagentHookObservation(observation)
    }
    // Observation Hooks never print a response, block execution, or surface
    // private payloads on stderr. Database failures deliberately fail open.
    exit(0)
}

if let sessionID = option("--replay-routing-prompt") {
    guard let model = option("--replay-model"), let effort = option("--replay-effort") else {
        fputs("token-pet-cli: --replay-model and --replay-effort are required\n", stderr)
        exit(2)
    }
    do {
        let prompt = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        guard !prompt.isEmpty else {
            fputs("token-pet-cli: replay prompt on stdin is empty\n", stderr)
            exit(2)
        }
        let store = try SQLiteStore(path: option("--db") ?? SessionScanner.defaultDatabasePath(environment: environment))
        try store.saveRoutingPreflightBypass(RoutingPreflightBypass(sessionID: sessionID, prompt: prompt))
        let receipt = try CodexDesktopTurnReplay.replay(
            sessionID: sessionID,
            prompt: prompt,
            model: model,
            reasoningEffort: effort)
        let output = try JSONSerialization.data(withJSONObject: [
            "turnId": receipt.turnID,
            "actualModel": receipt.actual.model,
            "actualEffort": receipt.actual.reasoningEffort,
        ], options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--user-prompt-submit-hook") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let envelope = routingHookEnvelope(data)
    let guardianDatabase = option("--db") ?? SessionScanner.defaultDatabasePath(environment: environment)
    let guardianStore = try? SQLiteStore(path: guardianDatabase)
    do {
        let input = try JSONDecoder().decode(RoutingPreflightHookInput.self, from: data)
        if (try? guardianStore?.consumeRoutingPreflightBypass(
            sessionID: input.sessionID,
            prompt: input.prompt)) == true {
            recordRoutingHookDiagnostic(
                store: guardianStore,
                sessionID: input.sessionID,
                outcome: .bypassed,
                reasonCode: "one_time_replay_bypass",
                inputKeys: envelope.keys)
            exit(0)
        }
        guard let transcriptPath = input.transcriptPath else {
            recordRoutingHookDiagnostic(
                store: guardianStore, sessionID: input.sessionID, outcome: .filtered,
                reasonCode: "transcript_path_missing", inputKeys: envelope.keys)
            exit(0)
        }
        let codexHome = SessionScanner.defaultCodexHome(environment: environment)
        let statePath = codexHome.appendingPathComponent("state_5.sqlite").path
        let databaseSelection = CodexThreadSelectionReader.read(
            sessionID: input.sessionID,
            databasePath: statePath)
        let rolloutFacts = databaseSelection == nil
            ? CodexRolloutPreflightReader.read(
                sessionID: input.sessionID,
                transcriptPath: transcriptPath)
            : nil
        guard var selection = databaseSelection ?? rolloutFacts?.selection else {
            // A brand-new Desktop task may not be committed to state_5.sqlite
            // yet. Fail open only when neither state nor turn_context provides
            // the actual configuration.
            recordRoutingHookDiagnostic(
                store: guardianStore,
                sessionID: input.sessionID,
                outcome: .filtered,
                reasonCode: "selection_unavailable",
                inputKeys: envelope.keys)
            exit(0)
        }
        if let hookModel = input.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hookModel.isEmpty {
            selection.model = hookModel
        }
        guard RoutingPreflightPolicy.isSupportedSelection(selection) else {
            recordRoutingHookDiagnostic(
                store: guardianStore, sessionID: input.sessionID, outcome: .filtered,
                reasonCode: "unsupported_selection", inputKeys: envelope.keys)
            exit(0)
        }
        let isTopLevel = if databaseSelection != nil {
            CodexThreadSelectionReader.isTopLevelUserTask(
                sessionID: input.sessionID,
                databasePath: statePath)
        } else {
            rolloutFacts?.isTopLevelUserTask == true
        }
        guard isTopLevel
        else {
            // Subagents and internal reviewers remain strictly excluded.
            recordRoutingHookDiagnostic(
                store: guardianStore, sessionID: input.sessionID, outcome: .filtered,
                reasonCode: "non_top_level_task", inputKeys: envelope.keys)
            exit(0)
        }
        var decision = RoutingPreflightPolicy.localDecision(input: input, selection: selection)
        if decision == nil, RoutingPreflightPolicy.needsBoundedModel(selection) {
            // Intelligent analysis is never started silently. A future consent
            // flow may launch it only after the user explicitly confirms.
            decision = .allow(
                reasonCode: "model_analysis_requires_user_consent",
                classifier: .failOpen)
        }

        let resolvedDecision = decision ?? .allow(
            reasonCode: "no_high_confidence_overprovision",
            classifier: .localRule)
        let observation = RoutingPreflightObservation(
            sessionID: input.sessionID,
            current: selection,
            decision: resolvedDecision)
        try? guardianStore?.recordRoutingPreflight(observation)
        recordRoutingHookDiagnostic(
            store: guardianStore,
            sessionID: input.sessionID,
            outcome: resolvedDecision.shouldBlock ? .blocked : .allowed,
            reasonCode: resolvedDecision.reasonCode,
            inputKeys: envelope.keys)

        if let response = resolvedDecision.hookResponse {
            if let recommended = observation.recommended {
                _ = RoutingPreflightBridgeClient.send(PendingRoutingReplay(
                    sessionID: input.sessionID,
                    prompt: input.prompt,
                    current: selection,
                    recommended: recommended,
                    reasonCode: resolvedDecision.reasonCode,
                    upgradeCondition: resolvedDecision.upgradeCondition,
                    observedAt: observation.observedAt))
            }
            let output = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
            FileHandle.standardOutput.write(output)
            FileHandle.standardOutput.write(Data([0x0A]))
        }
        exit(0)
    } catch {
        // Invalid or future hook input fails open and never prints the prompt to stderr.
        recordRoutingHookDiagnostic(
            store: guardianStore,
            sessionID: envelope.sessionID,
            outcome: .failed,
            reasonCode: "input_decode_or_handler_failed",
            inputKeys: envelope.keys)
        exit(0)
    }
}

if arguments.contains("--install-user-prompt-hook") {
    guard let command = option("--hook-command"), let file = option("--hooks-file") else {
        fputs("token-pet-cli: --hook-command and --hooks-file are required\n", stderr)
        exit(2)
    }
    do {
        let backup = try RoutingHookInstaller.install(
            command: command,
            hooksFile: URL(fileURLWithPath: file))
        let payload: [String: Any] = [
            "status": backup == nil ? "already-installed" : "installed",
            "backup": backup?.path as Any? ?? NSNull(),
        ]
        let output = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--install-subagent-hooks") {
    guard let command = option("--hook-command"), let file = option("--hooks-file") else {
        fputs("token-pet-cli: --hook-command and --hooks-file are required\n", stderr)
        exit(2)
    }
    do {
        let backup = try SubagentObservationHookInstaller.install(
            command: command,
            hooksFile: URL(fileURLWithPath: file))
        let payload: [String: Any] = [
            "status": backup == nil ? "already-installed" : "installed",
            "backup": backup?.path as Any? ?? NSNull(),
            "events": [SubagentHookEvent.start.rawValue, SubagentHookEvent.stop.rawValue],
        ]
        let output = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--run-eval-task") {
    guard let cwd = option("--eval-cwd"),
          let title = option("--eval-title"),
          let promptPath = option("--eval-prompt-file"),
          let model = option("--eval-model"),
          let effort = option("--eval-effort")
    else {
        fputs("token-pet-cli: --eval-cwd, --eval-title, --eval-prompt-file, --eval-model, and --eval-effort are required\n", stderr)
        exit(2)
    }
    do {
        let prompt = try String(contentsOfFile: promptPath, encoding: .utf8)
        let result = try CodexEvaluationTaskRunner().run(
            cwd: cwd,
            title: title,
            prompt: prompt,
            model: model,
            reasoningEffort: effort)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let contractPath = option("--route-task-contract") {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: contractPath))
        let contract = try JSONDecoder().decode(RoutingTaskContract.self, from: data)
        let decision = CodexQuotaRouterPolicy.decide(contract)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(decision), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let home = option("--home").map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? SessionScanner.defaultCodexHome(environment: environment)
let database = option("--db") ?? SessionScanner.defaultDatabasePath(environment: environment)
let limit = option("--limit").flatMap(Int.init) ?? 50

if let samplePath = option("--record-routing-evaluation") {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: samplePath))
        let sample = try JSONDecoder().decode(RoutingEvaluationSample.self, from: data)
        try SQLiteStore(path: database).upsertRoutingEvaluation(sample)
        print(#"{"status":"recorded"}"#)
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-evaluations") {
    do {
        let samples = try SQLiteStore(path: database).routingEvaluations(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(samples), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-outcomes") {
    do {
        let observations = try SQLiteStore(path: database).routingOutcomes(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(observations), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--execution-waste") {
    do {
        let observations = try SQLiteStore(path: database).executionWasteObservations(
            limit: limit,
            onlyWithEvidence: arguments.contains("--only-with-evidence"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(observations), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let observationID = option("--label-execution-waste") {
    guard let rawReason = option("--reason"),
          let reason = ExecutionWasteReason(rawValue: rawReason),
          let rawVerdict = option("--verdict"),
          let verdict = ExecutionWasteReviewVerdict(rawValue: rawVerdict),
          let rawRationale = option("--rationale"),
          let rationale = ExecutionWasteReviewRationale(rawValue: rawRationale)
    else {
        fputs("token-pet-cli: --reason, --verdict, and --rationale must use supported values\n", stderr)
        exit(2)
    }
    do {
        let label = try ExecutionWasteReviewLabel(
            observationID: observationID,
            reason: reason,
            verdict: verdict,
            rationale: rationale,
            recordedAt: Date())
        try SQLiteStore(path: database).upsertExecutionWasteReviewLabel(label)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(label), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--execution-waste-review") {
    do {
        let items = try SQLiteStore(path: database).executionWasteReviewItems(
            limit: limit,
            onlyUnlabeled: arguments.contains("--only-unlabeled"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(items), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--execution-waste-accuracy") {
    do {
        let minimumSamples = option("--minimum-conclusive-samples").flatMap(Int.init) ?? 30
        let precisionTarget = option("--precision-target").flatMap(Double.init) ?? 0.8
        let summary = try SQLiteStore(path: database).executionWasteAccuracySummary(
            minimumConclusiveSamples: minimumSamples,
            precisionTarget: precisionTarget)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(summary), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-preflights") {
    do {
        let observations = try SQLiteStore(path: database).routingPreflights(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(observations), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-hook-diagnostics") {
    do {
        let diagnostics = try SQLiteStore(path: database).routingHookDiagnostics(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(diagnostics), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--subagent-hook-diagnostics") {
    do {
        let observations = try SQLiteStore(path: database).subagentHookObservations(limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(observations), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--subagent-hook-health") {
    do {
        let store = try SQLiteStore(path: database)
        let scanner = SessionScanner(store: store, codexHome: home)
        let appServerHooks = (try? CodexHooksListReader.read(cwds: [FileManager.default.currentDirectoryPath])) ?? []
        let snapshot = try scanner.subagentHookHealth(appServerHooks: appServerHooks)
        try store.recordSubagentHookHealthDiagnostic(
            SubagentHookHealthDiagnostic(snapshot: snapshot))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-evaluation-summary") {
    guard let baselineEffort = option("--baseline-effort"),
          let candidateEffort = option("--candidate-effort")
    else {
        fputs("token-pet-cli: --baseline-effort and --candidate-effort are required\n", stderr)
        exit(2)
    }
    do {
        let samples = try SQLiteStore(path: database).routingEvaluations(limit: 2_000)
        let result = RoutingEvaluationGate.evaluate(
            samples,
            baselineEffort: baselineEffort,
            candidateEffort: candidateEffort)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let preset = option("--set-routing-profile") {
    guard [
        RoutingPreferenceProfile.currentHabitsPresetID,
        RoutingPreferenceProfile.controllerWorkerPresetID,
        "current-habits",
        "controller-worker",
    ].contains(preset) else {
        fputs("token-pet-cli: unsupported routing profile preset: \(preset)\n", stderr)
        exit(2)
    }
    do {
        let store = try SQLiteStore(path: database)
        let profile = RoutingPreferenceProfile.currentHabits()
        try store.saveRoutingPreferenceProfile(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(profile), as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--routing-profile") {
    do {
        let profile = try SQLiteStore(path: database).loadRoutingPreferenceProfile()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let profile {
            print(String(decoding: try encoder.encode(profile), as: UTF8.self))
        } else {
            print(#"{"status":"unconfirmed"}"#)
        }
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--shadow-report") {
    do {
        let summary = try SQLiteStore(path: database).shadowTelemetrySummary()
        let usage = summary.handoffUsage
        let payload: [String: Any] = [
            "policyVersion": HandoffShadowDecision.currentPolicyVersion,
            "decisions": [
                "total": summary.decisionCount,
                "continueCurrent": summary.continueCount,
                "observe": summary.observeCount,
                "prepareHandoff": summary.prepareHandoffCount,
            ],
            "handoffCosts": [
                "pending": summary.pendingHandoffCosts,
                "seeded": summary.seededHandoffCosts,
                "acknowledged": summary.acknowledgedHandoffCosts,
                "continued": summary.continuedHandoffCosts,
                "legacyComplete": summary.completedHandoffCosts,
                "quickCapsule": summary.quickCapsuleHandoffs,
                "fullSourceSummary": summary.fullSummaryHandoffs,
                "historyInjection": summary.historyInjectionHandoffs,
                "acknowledgementTurn": summary.acknowledgementTurnHandoffs,
                "input": usage.input,
                "cachedInput": usage.cachedInput,
                "cacheWriteInput": usage.cacheWriteInput,
                "uncachedInput": usage.uncachedInput,
                "output": usage.output,
                "reasoningOutput": usage.reasoningOutput,
                "total": usage.total,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--token-audit") {
    do {
        let days = max(1, option("--token-audit-days").flatMap(Int.init) ?? 90)
        let store = try SQLiteStore(path: database)
        let scanner = SessionScanner(store: store, codexHome: home)
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let scan = try scanner.indexHistory(since: since)
        try scanner.backfillRoutingOutcomes()
        try scanner.backfillExecutionWasteObservations()
        let audit = TaskEconomicsAudit.build(
            from: try scanner.economicsTurns(),
            routingPreferenceProfile: try store.loadRoutingPreferenceProfile())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let auditObject = try JSONSerialization.jsonObject(with: encoder.encode(audit))
        let payload: [String: Any] = [
            "lookbackDays": days,
            "scan": [
                "files": scan.scannedFiles,
                "bytesRead": scan.bytesRead,
                "changedTurns": scan.changedTurns,
            ],
            "audit": auditObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--multi-agent-audit") {
    do {
        let store = try SQLiteStore(path: database)
        let scanner = SessionScanner(store: store, codexHome: home)
        let days = max(1, option("--multi-agent-audit-days").flatMap(Int.init) ?? 7)
        let since = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        let scan = try scanner.indexHistory(since: since)
        let findings = MultiAgentAuditPolicy.evaluate(turns: try store.turns(limit: max(limit, 2_000)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let findingsObject = try JSONSerialization.jsonObject(with: encoder.encode(findings))
        let payload: [String: Any] = [
            "lookbackDays": days,
            "scan": [
                "files": scan.scannedFiles,
                "bytesRead": scan.bytesRead,
                "changedTurns": scan.changedTurns,
            ],
            "findings": findingsObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error)\n", stderr)
        exit(1)
    }
}

do {
    let store = try SQLiteStore(path: database)
    let scanner = SessionScanner(store: store, codexHome: home)
    let startedAt = Date()
    let scan = try scanner.initialIndex()
    try scanner.backfillRoutingOutcomes()
    try scanner.backfillExecutionWasteObservations()
    let snapshot = try scanner.snapshot(limit: limit)
    let payload: [String: Any] = [
        "codexHome": home.path,
        "database": database,
        "scan": [
            "files": scan.scannedFiles,
            "bytesRead": scan.bytesRead,
            "changedTurns": scan.changedTurns,
            "durationMs": Int(Date().timeIntervalSince(startedAt) * 1_000),
        ],
        "snapshot": [
            "indexedFiles": snapshot.indexedFiles,
            "activeTurns": snapshot.active.count,
            "activeSessions": snapshot.activeSessions.count,
            "startFreshSessions": snapshot.startFreshSessions.count,
            "recentHealthySessions": snapshot.recentHealthySessions.count,
            "recentTurns": snapshot.recent.count,
            "sessions": snapshot.sessions.count,
            "fallbackTitles": snapshot.sessions.filter { $0.title.contains(" · ") && $0.title.contains(",") }.count,
            "remainingQuota": snapshot.latestQuota?.remainingPercent ?? -1,
            "highestRisk": snapshot.highestRisk.rawValue,
            "healthPolicy": [
                "mode": snapshot.healthPolicy.calibrationLabel,
                "amberContextPercent": Int(snapshot.healthPolicy.amberContext * 100),
                "redContextPercent": Int(snapshot.healthPolicy.redContext * 100),
                "freshInputSamples": snapshot.healthPolicy.freshInputSampleCount,
                "compactionSamples": snapshot.healthPolicy.compactionSampleCount,
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
} catch {
    fputs("token-pet-cli: \(error)\n", stderr)
    exit(1)
}
