import Foundation
import TokenPetCore

var arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

let environment = ProcessInfo.processInfo.environment

if let probeThreadID = option("--probe-desktop-thread") {
    do {
        print(try CodexHandoffMigrator.probeDesktopThread(probeThreadID))
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
            sourceTitle: option("--migrate-title") ?? "Continued task",
            cwd: cwd,
            interruptActiveTurn: arguments.contains("--interrupt-active"),
            currentTurnID: option("--active-turn-id"),
            progress: { fputs("token-pet-cli: \($0)\n", stderr) })
        let data = try JSONSerialization.data(withJSONObject: [
            "sourceThreadId": result.sourceThreadID,
            "newThreadId": result.newThreadID,
            "handoffCharacters": result.handoff.count,
        ], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
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

do {
    let store = try SQLiteStore(path: database)
    let scanner = SessionScanner(store: store, codexHome: home)
    let startedAt = Date()
    let scan = try scanner.initialIndex()
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
