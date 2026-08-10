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
