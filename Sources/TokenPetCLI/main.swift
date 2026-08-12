import Foundation
import TokenPetCore

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let environment = ProcessInfo.processInfo.environment

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
        let turnID = try CodexDesktopTurnReplay.replay(
            sessionID: sessionID,
            prompt: prompt,
            model: model,
            reasoningEffort: effort)
        let output = try JSONSerialization.data(withJSONObject: ["turnId": turnID], options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if arguments.contains("--user-prompt-submit-hook") {
    do {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let input = try JSONDecoder().decode(RoutingPreflightHookInput.self, from: data)
        let guardianDatabase = option("--db") ?? SessionScanner.defaultDatabasePath(environment: environment)
        let guardianStore = try? SQLiteStore(path: guardianDatabase)
        if (try? guardianStore?.consumeRoutingPreflightBypass(
            sessionID: input.sessionID,
            prompt: input.prompt)) == true {
            exit(0)
        }
        let codexHome = SessionScanner.defaultCodexHome(environment: environment)
        let statePath = codexHome.appendingPathComponent("state_5.sqlite").path
        guard var selection = CodexThreadSelectionReader.read(
            sessionID: input.sessionID,
            databasePath: statePath)
        else {
            // The hook must never stop a task merely because a private Codex schema changed.
            exit(0)
        }
        if let hookModel = input.model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !hookModel.isEmpty {
            selection.model = hookModel
        }
        guard RoutingPreflightPolicy.isSupportedSelection(selection),
              CodexThreadSelectionReader.isTopLevelUserTask(
                sessionID: input.sessionID,
                databasePath: statePath),
              let transcriptPath = input.transcriptPath,
              RoutingReplaySafety.isTurnActive(transcriptPath: transcriptPath) == false
        else {
            // Internal reviewers, subagents, hidden tasks, unsupported models,
            // and any task with an active writer are never routed or replayed.
            exit(0)
        }

        var decision = RoutingPreflightPolicy.localDecision(input: input, selection: selection)
        var classifierDuration: Double?
        var classifierUsage: TokenUsage?
        if decision == nil, RoutingPreflightPolicy.needsBoundedModel(selection) {
            do {
                let prompt = RoutingPreflightPolicy.boundedClassifierPrompt(
                    userPrompt: input.prompt,
                    current: selection)
                let result = try CodexEvaluationTaskRunner(timeout: 12).classifyPreflight(
                    cwd: input.cwd,
                    prompt: prompt)
                classifierDuration = result.durationSeconds
                classifierUsage = result.usage
                if let decoded = RoutingPreflightPolicy.decodeModelDecision(result.output) {
                    decision = RoutingPreflightPolicy.validateModelDecision(decoded, current: selection)
                }
            } catch {
                // Timeout, unavailable model, malformed output, and app-server drift all fail open.
                decision = .allow(reasonCode: "classifier_unavailable", classifier: .failOpen)
            }
        }

        let resolvedDecision = decision ?? .allow(
            reasonCode: "no_high_confidence_overprovision",
            classifier: .localRule)
        let observation = RoutingPreflightObservation(
            sessionID: input.sessionID,
            current: selection,
            decision: resolvedDecision,
            classifierDurationSeconds: classifierDuration,
            classifierUsage: classifierUsage)
        try? guardianStore?.recordRoutingPreflight(observation)

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

if let probeThreadID = option("--probe-desktop-thread") {
    do {
        print(try CodexHandoffMigrator.probeDesktopThread(probeThreadID))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let sourceThreadID = option("--quick-handoff-check") {
    guard let cwd = option("--migrate-cwd") else {
        fputs("token-pet-cli: --migrate-cwd is required with --quick-handoff-check\n", stderr)
        exit(2)
    }
    do {
        let diagnostics = try QuickHandoffCapsuleCompiler.diagnostics(
            sourceThreadID: sourceThreadID,
            title: option("--migrate-title") ?? "续接任务",
            cwd: cwd)
        let capsule = try QuickHandoffCapsuleCompiler.compile(
            sourceThreadID: sourceThreadID,
            title: option("--migrate-title") ?? "续接任务",
            cwd: cwd)
        let payload: [String: Any] = [
            "eligible": capsule != nil,
            "capsuleUtf8Bytes": capsule?.text.utf8.count ?? 0,
            "sourceBytesRead": capsule?.sourceBytesRead ?? 0,
            "sourceMessagesUsed": capsule?.sourceMessagesUsed ?? 0,
            "maximumCapsuleUtf8Bytes": QuickHandoffCapsuleCompiler.maximumCapsuleUTF8Bytes,
            "diagnostics": [
                "sourceBytesRead": diagnostics.sourceBytesRead,
                "userMessages": diagnostics.userMessages,
                "publicAgentMessages": diagnostics.publicAgentMessages,
                "changedFiles": diagnostics.changedFiles,
                "hasInheritedHandoff": diagnostics.hasInheritedHandoff,
                "hasStructuredAgentSummary": diagnostics.hasStructuredAgentSummary,
                "structuredHasState": diagnostics.structuredHasState,
                "structuredHasVerified": diagnostics.structuredHasVerified,
                "structuredHasConstraints": diagnostics.structuredHasConstraints,
                "substantiveUserMessages": diagnostics.substantiveUserMessages,
                "substantiveAgentMessages": diagnostics.substantiveAgentMessages,
                "candidateUtf8Bytes": diagnostics.candidateUTF8Bytes ?? 0,
                "buildSucceeded": diagnostics.buildSucceeded,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    } catch {
        fputs("token-pet-cli: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if let sourceThreadID = option("--migrate-thread") {
    guard let cwd = option("--migrate-cwd") else {
        fputs("token-pet-cli: --migrate-cwd is required with --migrate-thread\n", stderr)
        exit(2)
    }
    do {
        let result = try CodexHandoffMigrator().migrate(
            sourceThreadID: sourceThreadID,
            sourceTitle: option("--migrate-title") ?? "续接任务",
            cwd: cwd,
            interruptActiveTurn: arguments.contains("--interrupt-active"),
            currentTurnID: option("--active-turn-id"),
            progress: { fputs("token-pet-cli: \($0)\n", stderr) })
        let sourceSummaryTurnID: Any = result.sourceSummaryTurnID.map { $0 as Any } ?? NSNull()
        let destinationAcknowledgementTurnID: Any = result.destinationAcknowledgementTurnID
            .map { $0 as Any } ?? NSNull()
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceThreadId": result.sourceThreadID,
            "newThreadId": result.newThreadID,
            "sourceSummaryTurnId": sourceSummaryTurnID,
            "destinationAcknowledgementTurnId": destinationAcknowledgementTurnID,
            "preparationMethod": result.preparationMethod.rawValue,
            "deliveryMethod": result.deliveryMethod.rawValue,
            "handoffCharacters": result.handoff.count,
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
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
                "complete": summary.completedHandoffCosts,
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
