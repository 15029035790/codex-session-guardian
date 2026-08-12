import CSQLite3
import Foundation

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct FileCursor: Codable, Sendable {
    public var identity: String
    public var path: String
    public var offset: UInt64
    public var remainder: Data
    public var state: RolloutState

    public init(identity: String, path: String) {
        self.identity = identity
        self.path = path
        self.offset = 0
        self.remainder = Data()
        self.state = RolloutState()
    }
}

public final class SQLiteStore: @unchecked Sendable {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()

    public init(path: String) throws {
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
        else { throw StoreError.open(message) }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("""
            CREATE TABLE IF NOT EXISTS file_cursors (
                identity TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                offset INTEGER NOT NULL,
                remainder BLOB NOT NULL,
                state BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS turns (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                status TEXT NOT NULL,
                started_at REAL,
                completed_at REAL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS turns_recent ON turns(COALESCE(completed_at, started_at) DESC)")
        try execute("CREATE INDEX IF NOT EXISTS turns_status ON turns(status)")
        try execute("""
            CREATE TABLE IF NOT EXISTS handoff_shadow_decisions (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                turn_ordinal INTEGER NOT NULL,
                observed_at REAL NOT NULL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS handoff_shadow_session ON handoff_shadow_decisions(session_id, turn_ordinal)")
        try execute("""
            CREATE TABLE IF NOT EXISTS handoff_costs (
                id TEXT PRIMARY KEY,
                source_session_id TEXT NOT NULL,
                destination_session_id TEXT NOT NULL,
                started_at REAL NOT NULL,
                status TEXT NOT NULL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS handoff_costs_status ON handoff_costs(status, started_at DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS routing_preferences (
                id TEXT PRIMARY KEY,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("""
            CREATE TABLE IF NOT EXISTS routing_evaluations (
                id TEXT PRIMARY KEY,
                comparison_id TEXT NOT NULL,
                recorded_at REAL NOT NULL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS routing_evaluations_comparison ON routing_evaluations(comparison_id, recorded_at)")
        try execute("""
            CREATE TABLE IF NOT EXISTS routing_outcomes (
                id TEXT PRIMARY KEY,
                observed_at REAL NOT NULL,
                model TEXT NOT NULL,
                reasoning_effort TEXT NOT NULL,
                quality_evidence TEXT NOT NULL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS routing_outcomes_route ON routing_outcomes(model, reasoning_effort, observed_at DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS routing_preflight_observations (
                id TEXT PRIMARY KEY,
                observed_at REAL NOT NULL,
                blocked INTEGER NOT NULL,
                data BLOB NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute("CREATE INDEX IF NOT EXISTS routing_preflight_recent ON routing_preflight_observations(observed_at DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS routing_preflight_bypasses (
                session_hash TEXT NOT NULL,
                prompt_hash TEXT NOT NULL,
                expires_at REAL NOT NULL,
                PRIMARY KEY(session_hash, prompt_hash)
            )
            """)
    }

    deinit { sqlite3_close(database) }

    public func loadCursor(identity: String) throws -> FileCursor? {
        try locked {
            let statement = try prepare("SELECT path, offset, remainder, state FROM file_cursors WHERE identity = ?")
            defer { sqlite3_finalize(statement) }
            bind(identity, to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            guard let pathPointer = sqlite3_column_text(statement, 0) else { return nil }
            let path = String(cString: pathPointer)
            let offset = UInt64(max(0, sqlite3_column_int64(statement, 1)))
            let remainder = data(statement, column: 2)
            let stateData = data(statement, column: 3)
            let state = try decoder.decode(RolloutState.self, from: stateData)
            return FileCursor(identity: identity, path: path, offset: offset, remainder: remainder, state: state)
        }
    }

    public func save(cursor: FileCursor) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO file_cursors(identity, path, offset, remainder, state, updated_at)
                VALUES(?, ?, ?, ?, ?, ?)
                ON CONFLICT(identity) DO UPDATE SET
                    path=excluded.path, offset=excluded.offset, remainder=excluded.remainder,
                    state=excluded.state, updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(cursor.identity, to: statement, at: 1)
            bind(cursor.path, to: statement, at: 2)
            sqlite3_bind_int64(statement, 3, sqlite3_int64(cursor.offset))
            bind(cursor.remainder, to: statement, at: 4)
            bind(try encoder.encode(cursor.state), to: statement, at: 5)
            sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func upsert(turn: TurnRecord) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO turns(id, session_id, status, started_at, completed_at, data, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    status=excluded.status, started_at=excluded.started_at,
                    completed_at=excluded.completed_at, data=excluded.data, updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(turn.id, to: statement, at: 1)
            bind(turn.sessionID, to: statement, at: 2)
            bind(turn.status.rawValue, to: statement, at: 3)
            bind(turn.startedAt, to: statement, at: 4)
            bind(turn.completedAt, to: statement, at: 5)
            bind(try encoder.encode(turn), to: statement, at: 6)
            sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func deleteTurns(sessionID: String) throws {
        try locked {
            let statement = try prepare("DELETE FROM turns WHERE session_id = ?")
            defer { sqlite3_finalize(statement) }
            bind(sessionID, to: statement, at: 1)
            try stepDone(statement)
        }
    }

    public func turns(status: TurnStatus? = nil, limit: Int = 50) throws -> [TurnRecord] {
        try locked {
            let sql: String
            if status == nil {
                sql = "SELECT data FROM turns ORDER BY COALESCE(completed_at, started_at) DESC LIMIT ?"
            } else {
                sql = "SELECT data FROM turns WHERE status = ? ORDER BY started_at DESC LIMIT ?"
            }
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            var index: Int32 = 1
            if let status {
                bind(status.rawValue, to: statement, at: index)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(limit))
            var result: [TurnRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(TurnRecord.self, from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func indexedFileCount() throws -> Int {
        try locked {
            let statement = try prepare("SELECT COUNT(*) FROM file_cursors")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func archivedSessionIDs() throws -> Set<String> {
        try locked {
            let statement = try prepare("SELECT state FROM file_cursors WHERE path LIKE '%/archived_sessions/%'")
            defer { sqlite3_finalize(statement) }
            var result = Set<String>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let state = try? decoder.decode(RolloutState.self, from: data(statement, column: 0)),
                   let id = state.sessionID
                {
                    result.insert(id)
                }
            }
            return result
        }
    }

    public func nonRunningTurnCount(limit: Int = 50) throws -> Int {
        try locked {
            let statement = try prepare("SELECT MIN(COUNT(*), ?) FROM turns WHERE status != ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(limit))
            bind(TurnStatus.running.rawValue, to: statement, at: 2)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func loadRoutingPreferenceProfile() throws -> RoutingPreferenceProfile? {
        try locked {
            let statement = try prepare("SELECT data FROM routing_preferences WHERE id = 'active' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return try decoder.decode(RoutingPreferenceProfile.self, from: data(statement, column: 0))
        }
    }

    public func saveRoutingPreferenceProfile(_ profile: RoutingPreferenceProfile) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO routing_preferences(id, data, updated_at)
                VALUES('active', ?, ?)
                ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(try encoder.encode(profile), to: statement, at: 1)
            sqlite3_bind_double(statement, 2, profile.updatedAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func upsertRoutingEvaluation(_ sample: RoutingEvaluationSample) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO routing_evaluations(id, comparison_id, recorded_at, data, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    comparison_id=excluded.comparison_id,
                    recorded_at=excluded.recorded_at,
                    data=excluded.data,
                    updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(sample.id, to: statement, at: 1)
            bind(sample.comparisonID, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, sample.recordedAt.timeIntervalSince1970)
            bind(try encoder.encode(sample), to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func routingEvaluations(limit: Int = 100) throws -> [RoutingEvaluationSample] {
        try locked {
            let statement = try prepare("""
                SELECT data FROM routing_evaluations
                ORDER BY recorded_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [RoutingEvaluationSample] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(
                    RoutingEvaluationSample.self,
                    from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func upsertRoutingOutcome(_ observation: RoutingOutcomeObservation) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO routing_outcomes(
                    id, observed_at, model, reasoning_effort, quality_evidence, data, updated_at)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    observed_at=excluded.observed_at,
                    model=excluded.model,
                    reasoning_effort=excluded.reasoning_effort,
                    quality_evidence=excluded.quality_evidence,
                    data=excluded.data,
                    updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(observation.id, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, observation.observedAt.timeIntervalSince1970)
            bind(observation.model, to: statement, at: 3)
            bind(observation.reasoningEffort, to: statement, at: 4)
            bind(observation.qualityEvidence.rawValue, to: statement, at: 5)
            bind(try encoder.encode(observation), to: statement, at: 6)
            sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func routingOutcomes(limit: Int = 10_000) throws -> [RoutingOutcomeObservation] {
        try locked {
            let statement = try prepare("""
                SELECT data FROM routing_outcomes
                ORDER BY observed_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [RoutingOutcomeObservation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(
                    RoutingOutcomeObservation.self,
                    from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func recordRoutingPreflight(_ observation: RoutingPreflightObservation) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO routing_preflight_observations(id, observed_at, blocked, data, updated_at)
                VALUES(?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    observed_at=excluded.observed_at,
                    blocked=excluded.blocked,
                    data=excluded.data,
                    updated_at=excluded.updated_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(observation.id, to: statement, at: 1)
            sqlite3_bind_double(statement, 2, observation.observedAt.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, observation.blocked ? 1 : 0)
            bind(try encoder.encode(observation), to: statement, at: 4)
            sqlite3_bind_double(statement, 5, Date().timeIntervalSince1970)
            try stepDone(statement)
            try execute("""
                DELETE FROM routing_preflight_observations
                WHERE id NOT IN (
                    SELECT id FROM routing_preflight_observations
                    ORDER BY observed_at DESC LIMIT 2000
                )
                """)
        }
    }

    public func routingPreflights(limit: Int = 100) throws -> [RoutingPreflightObservation] {
        try locked {
            let statement = try prepare("""
                SELECT data FROM routing_preflight_observations
                ORDER BY observed_at DESC, id ASC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [RoutingPreflightObservation] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(
                    RoutingPreflightObservation.self,
                    from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func saveRoutingPreflightBypass(_ bypass: RoutingPreflightBypass) throws {
        try locked {
            let statement = try prepare("""
                INSERT INTO routing_preflight_bypasses(session_hash, prompt_hash, expires_at)
                VALUES(?, ?, ?)
                ON CONFLICT(session_hash, prompt_hash) DO UPDATE SET expires_at=excluded.expires_at
                """)
            defer { sqlite3_finalize(statement) }
            bind(bypass.sessionHash, to: statement, at: 1)
            bind(bypass.promptHash, to: statement, at: 2)
            sqlite3_bind_double(statement, 3, bypass.expiresAt.timeIntervalSince1970)
            try stepDone(statement)
        }
    }

    public func consumeRoutingPreflightBypass(sessionID: String, prompt: String, now: Date = Date()) throws -> Bool {
        try locked {
            let sessionHash = RoutingPreflightObservation.opaqueHash(sessionID)
            let promptHash = RoutingPreflightObservation.opaqueHash(prompt)
            try execute("BEGIN IMMEDIATE")
            do {
                let statement = try prepare("""
                    SELECT expires_at FROM routing_preflight_bypasses
                    WHERE session_hash = ? AND prompt_hash = ? LIMIT 1
                    """)
                bind(sessionHash, to: statement, at: 1)
                bind(promptHash, to: statement, at: 2)
                let exists = sqlite3_step(statement) == SQLITE_ROW
                let expiresAt = exists ? sqlite3_column_double(statement, 0) : 0
                sqlite3_finalize(statement)
                let delete = try prepare("""
                    DELETE FROM routing_preflight_bypasses
                    WHERE (session_hash = ? AND prompt_hash = ?) OR expires_at <= ?
                    """)
                bind(sessionHash, to: delete, at: 1)
                bind(promptHash, to: delete, at: 2)
                sqlite3_bind_double(delete, 3, now.timeIntervalSince1970)
                try stepDone(delete)
                sqlite3_finalize(delete)
                try execute("COMMIT")
                return exists && expiresAt > now.timeIntervalSince1970
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func recordShadowCompletion(
        decision: HandoffShadowDecision,
        completedTurn: TurnRecord
    ) throws {
        try locked {
            try execute("BEGIN IMMEDIATE")
            do {
                let existing = try prepare("SELECT 1 FROM handoff_shadow_decisions WHERE id = ? LIMIT 1")
                bind(decision.id, to: existing, at: 1)
                let duplicate = sqlite3_step(existing) == SQLITE_ROW
                sqlite3_finalize(existing)
                if duplicate {
                    try execute("COMMIT")
                    return
                }

                let priorStatement = try prepare("""
                    SELECT data FROM handoff_shadow_decisions
                    WHERE session_id = ? AND turn_ordinal < ?
                    ORDER BY turn_ordinal ASC
                    """)
                bind(decision.sessionID, to: priorStatement, at: 1)
                sqlite3_bind_int(priorStatement, 2, Int32(decision.turnOrdinal))
                var prior: [HandoffShadowDecision] = []
                while sqlite3_step(priorStatement) == SQLITE_ROW {
                    prior.append(try decoder.decode(
                        HandoffShadowDecision.self,
                        from: data(priorStatement, column: 0)))
                }
                sqlite3_finalize(priorStatement)

                for var value in prior {
                    value.observeFollowUp(
                        completedTurn,
                        sessionRisk: decision.risk,
                        at: decision.observedAt)
                    try upsertShadowDecisionUnlocked(value)
                }
                try upsertShadowDecisionUnlocked(decision)
                try execute("""
                    DELETE FROM handoff_shadow_decisions
                    WHERE id NOT IN (
                        SELECT id FROM handoff_shadow_decisions
                        ORDER BY observed_at DESC LIMIT 2000
                    )
                    """)
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    public func shadowDecisions(limit: Int = 100) throws -> [HandoffShadowDecision] {
        try locked {
            let statement = try prepare("""
                SELECT data FROM handoff_shadow_decisions
                ORDER BY observed_at DESC LIMIT ?
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [HandoffShadowDecision] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(
                    HandoffShadowDecision.self,
                    from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func upsertHandoffCost(_ record: HandoffCostRecord) throws {
        try locked { try upsertHandoffCostUnlocked(record) }
    }

    public func handoffCosts(limit: Int = 100) throws -> [HandoffCostRecord] {
        try locked {
            let statement = try prepare("SELECT data FROM handoff_costs ORDER BY started_at DESC LIMIT ?")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
            var result: [HandoffCostRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(try decoder.decode(HandoffCostRecord.self, from: data(statement, column: 0)))
            }
            return result
        }
    }

    public func reconcilePendingHandoffCosts(at now: Date = Date()) throws {
        try locked {
            let statement = try prepare("SELECT data FROM handoff_costs WHERE status = ?")
            bind(HandoffCostStatus.pending.rawValue, to: statement, at: 1)
            var pending: [HandoffCostRecord] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                pending.append(try decoder.decode(HandoffCostRecord.self, from: data(statement, column: 0)))
            }
            sqlite3_finalize(statement)

            for var record in pending {
                let source: TurnRecord?
                if let sourceTurnID = record.sourceSummaryTurnID {
                    source = try turnUnlocked(id: "\(record.sourceSessionID):\(sourceTurnID)")
                    guard source != nil else { continue }
                } else {
                    source = nil
                }
                let destination: TurnRecord?
                if let destinationTurnID = record.destinationAcknowledgementTurnID {
                    destination = try turnUnlocked(
                        id: "\(record.destinationSessionID):\(destinationTurnID)")
                    guard destination != nil else { continue }
                } else {
                    destination = nil
                }
                record.sourceUsage = source?.usage ?? TokenUsage()
                record.destinationUsage = destination?.usage ?? TokenUsage()
                record.completedAt = [source?.completedAt, destination?.completedAt]
                    .compactMap { $0 }
                    .max() ?? now
                record.status = .complete
                try upsertHandoffCostUnlocked(record)
            }
        }
    }

    public func shadowTelemetrySummary() throws -> HandoffShadowTelemetrySummary {
        let decisions = try shadowDecisions(limit: 2000)
        let costs = try handoffCosts(limit: 200)
        let completed = costs.filter { $0.status == .complete }
        let usage = completed.reduce(into: TokenUsage()) { $0 = $0 + $1.totalUsage }
        return HandoffShadowTelemetrySummary(
            decisionCount: decisions.count,
            continueCount: decisions.filter { $0.recommendation == .continueCurrent }.count,
            observeCount: decisions.filter { $0.recommendation == .observe }.count,
            prepareHandoffCount: decisions.filter { $0.recommendation == .prepareHandoff }.count,
            pendingHandoffCosts: costs.filter { $0.status == .pending }.count,
            completedHandoffCosts: completed.count,
            quickCapsuleHandoffs: completed.filter { $0.preparationMethod == .quickCapsule }.count,
            fullSummaryHandoffs: completed.filter { $0.preparationMethod == .fullSourceSummary }.count,
            historyInjectionHandoffs: completed.filter { $0.deliveryMethod == .historyInjection }.count,
            acknowledgementTurnHandoffs: completed.filter { $0.deliveryMethod == .acknowledgementTurn }.count,
            handoffUsage: usage)
    }

    private var message: String {
        database.flatMap(sqlite3_errmsg).map(String.init(cString:)) ?? "unknown SQLite error"
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.query(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.query(message)
        }
        return statement
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.query(message) }
    }

    private func upsertShadowDecisionUnlocked(_ decision: HandoffShadowDecision) throws {
        let statement = try prepare("""
            INSERT INTO handoff_shadow_decisions(id, session_id, turn_ordinal, observed_at, data, updated_at)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(decision.id, to: statement, at: 1)
        bind(decision.sessionID, to: statement, at: 2)
        sqlite3_bind_int(statement, 3, Int32(decision.turnOrdinal))
        sqlite3_bind_double(statement, 4, decision.observedAt.timeIntervalSince1970)
        bind(try encoder.encode(decision), to: statement, at: 5)
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func upsertHandoffCostUnlocked(_ record: HandoffCostRecord) throws {
        let statement = try prepare("""
            INSERT INTO handoff_costs(
                id, source_session_id, destination_session_id, started_at, status, data, updated_at)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status=excluded.status, data=excluded.data, updated_at=excluded.updated_at
            """)
        defer { sqlite3_finalize(statement) }
        bind(record.id, to: statement, at: 1)
        bind(record.sourceSessionID, to: statement, at: 2)
        bind(record.destinationSessionID, to: statement, at: 3)
        sqlite3_bind_double(statement, 4, record.startedAt.timeIntervalSince1970)
        bind(record.status.rawValue, to: statement, at: 5)
        bind(try encoder.encode(record), to: statement, at: 6)
        sqlite3_bind_double(statement, 7, Date().timeIntervalSince1970)
        try stepDone(statement)
        try execute("""
            DELETE FROM handoff_costs
            WHERE id NOT IN (
                SELECT id FROM handoff_costs ORDER BY started_at DESC LIMIT 200
            )
            """)
    }

    private func turnUnlocked(id: String) throws -> TurnRecord? {
        let statement = try prepare("SELECT data FROM turns WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id, to: statement, at: 1)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return try decoder.decode(TurnRecord.self, from: data(statement, column: 0))
    }

    private func bind(_ value: String, to statement: OpaquePointer?, at index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func bind(_ value: Data, to statement: OpaquePointer?, at index: Int32) {
        _ = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
    }

    private func bind(_ value: Date?, to statement: OpaquePointer?, at index: Int32) {
        if let value { sqlite3_bind_double(statement, index, value.timeIntervalSince1970) }
        else { sqlite3_bind_null(statement, index) }
    }

    private func data(_ statement: OpaquePointer?, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    public enum StoreError: Error, CustomStringConvertible {
        case open(String)
        case query(String)
        public var description: String {
            switch self {
            case let .open(value): "SQLite open failed: \(value)"
            case let .query(value): "SQLite query failed: \(value)"
            }
        }
    }
}

private extension FileCursor {
    init(identity: String, path: String, offset: UInt64, remainder: Data, state: RolloutState) {
        self.identity = identity
        self.path = path
        self.offset = offset
        self.remainder = remainder
        self.state = state
    }
}
