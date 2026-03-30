import Foundation
import SQLCipher

enum WidgetStorageEngineError: LocalizedError {
    case openFailed(String)
    case executeFailed(String)
    case prepareFailed(String)
    case bindFailed(String)
    case stepFailed(String)
    case decodeFailed(String)
    case storageModeMismatch(expectedEncrypted: Bool, existingEncrypted: Bool)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message),
             .executeFailed(let message),
             .prepareFailed(let message),
             .bindFailed(let message),
             .stepFailed(let message),
             .decodeFailed(let message):
            return message
        case .storageModeMismatch(let expectedEncrypted, let existingEncrypted):
            let expected = expectedEncrypted ? "encrypted" : "plaintext"
            let existing = existingEncrypted ? "encrypted" : "plaintext"
            return "Widget storage mode mismatch: requested \(expected) storage but existing database is \(existing)."
        }
    }
}

final class WidgetStorageEngine {
    private enum StorageMode: String {
        case plaintext
        case encrypted

        init(encryptionEnabled: Bool) {
            self = encryptionEnabled ? .encrypted : .plaintext
        }

        var isEncrypted: Bool {
            self == .encrypted
        }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let secretProvider: WidgetStorageSecretProviding
    private let encryptionEnabled: Bool
    private let log: (String) -> Void
    private var handles: [String: OpaquePointer] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileManager: FileManager,
        rootURL: URL,
        secretProvider: WidgetStorageSecretProviding,
        encryptionEnabled: Bool,
        log: @escaping (String) -> Void
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
        self.secretProvider = secretProvider
        self.encryptionEnabled = encryptionEnabled
        self.log = log
    }

    deinit {
        for (_, handle) in handles {
            sqlite3_close(handle)
        }
    }

    func allItems(widgetID: String, instanceID: String) throws -> [String: RuntimeJSONValue] {
        let db = try databaseHandle(for: widgetID)
        let sql = "SELECT key, value_json FROM storage WHERE instance_id = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WidgetStorageEngineError.prepareFailed(lastError(on: db))
        }
        defer { sqlite3_finalize(statement) }

        try bind(instanceID, at: 1, in: statement, db: db)

        var items: [String: RuntimeJSONValue] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE {
                return items
            }
            guard result == SQLITE_ROW else {
                throw WidgetStorageEngineError.stepFailed(lastError(on: db))
            }

            guard let keyCString = sqlite3_column_text(statement, 0) else {
                continue
            }
            let key = String(cString: keyCString)
            guard let blob = sqlite3_column_blob(statement, 1) else {
                items[key] = .null
                continue
            }
            let length = Int(sqlite3_column_bytes(statement, 1))
            let data = Data(bytes: blob, count: length)
            do {
                items[key] = try decoder.decode(RuntimeJSONValue.self, from: data)
            } catch {
                throw WidgetStorageEngineError.decodeFailed(error.localizedDescription)
            }
        }
    }

    func setItem(widgetID: String, instanceID: String, key: String, value: RuntimeJSONValue) throws {
        let db = try databaseHandle(for: widgetID)
        let sql = """
        INSERT INTO storage (instance_id, key, value_json, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(instance_id, key) DO UPDATE SET
            value_json = excluded.value_json,
            updated_at = excluded.updated_at;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WidgetStorageEngineError.prepareFailed(lastError(on: db))
        }
        defer { sqlite3_finalize(statement) }

        let encodedValue = try encoder.encode(value)
        try bind(instanceID, at: 1, in: statement, db: db)
        try bind(key, at: 2, in: statement, db: db)
        try bind(data: encodedValue, at: 3, in: statement, db: db)
        guard sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970) == SQLITE_OK else {
            throw WidgetStorageEngineError.bindFailed(lastError(on: db))
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WidgetStorageEngineError.stepFailed(lastError(on: db))
        }
    }

    func removeItem(widgetID: String, instanceID: String, key: String) throws {
        let db = try databaseHandle(for: widgetID)
        let sql = "DELETE FROM storage WHERE instance_id = ? AND key = ?;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WidgetStorageEngineError.prepareFailed(lastError(on: db))
        }
        defer { sqlite3_finalize(statement) }

        try bind(instanceID, at: 1, in: statement, db: db)
        try bind(key, at: 2, in: statement, db: db)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw WidgetStorageEngineError.stepFailed(lastError(on: db))
        }
    }

    private func databaseHandle(for widgetID: String) throws -> OpaquePointer {
        if let existing = handles[widgetID] {
            return existing
        }

        do {
            let handle = try openDatabase(for: widgetID)
            handles[widgetID] = handle
            return handle
        } catch {
            guard shouldResetDatabase(after: error) else {
                throw error
            }
            log("Widget storage: resetting database for \(widgetID): \(error.localizedDescription)")
            closeHandle(for: widgetID)
            try resetDatabaseDirectory(for: widgetID)
            let handle = try openDatabase(for: widgetID)
            handles[widgetID] = handle
            return handle
        }
    }

    private func openDatabase(for widgetID: String) throws -> OpaquePointer {
        let directoryURL = dataDirectory(for: widgetID)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let currentMode = StorageMode(encryptionEnabled: encryptionEnabled)
        if let existingMode = try readStorageMode(at: directoryURL),
           existingMode != currentMode {
            throw WidgetStorageEngineError.storageModeMismatch(
                expectedEncrypted: currentMode.isEncrypted,
                existingEncrypted: existingMode.isEncrypted
            )
        }
        let databaseURL = directoryURL.appendingPathComponent("storage.sqlite")

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw WidgetStorageEngineError.openFailed(lastError(on: db))
        }

        do {
            if encryptionEnabled {
                let key = try secretProvider.key(for: widgetID)
                let status = key.withUnsafeBytes { bytes in
                    sqlite3_key(db, bytes.baseAddress, Int32(bytes.count))
                }
                guard status == SQLITE_OK else {
                    throw WidgetStorageEngineError.openFailed(lastError(on: db))
                }
            }

            try execute("PRAGMA journal_mode = WAL;", on: db)
            try execute("PRAGMA synchronous = NORMAL;", on: db)
            try execute(
                """
                CREATE TABLE IF NOT EXISTS storage (
                    instance_id TEXT NOT NULL,
                    key TEXT NOT NULL,
                    value_json BLOB NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (instance_id, key)
                );
                """,
                on: db
            )
            try writeStorageMode(currentMode, at: directoryURL)
            return db
        } catch {
            sqlite3_close(db)
            throw error
        }
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw WidgetStorageEngineError.executeFailed(lastError(on: db))
        }
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer?, db: OpaquePointer) throws {
        guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
            throw WidgetStorageEngineError.bindFailed(lastError(on: db))
        }
    }

    private func bind(data: Data, at index: Int32, in statement: OpaquePointer?, db: OpaquePointer) throws {
        let result = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
        guard result == SQLITE_OK else {
            throw WidgetStorageEngineError.bindFailed(lastError(on: db))
        }
    }

    private func lastError(on db: OpaquePointer?) -> String {
        if let db, let message = sqlite3_errmsg(db) {
            return String(cString: message)
        }
        return "Unknown SQLite error."
    }

    private func closeHandle(for widgetID: String) {
        if let handle = handles.removeValue(forKey: widgetID) {
            sqlite3_close(handle)
        }
    }

    private func resetDatabaseDirectory(for widgetID: String) throws {
        let directoryURL = dataDirectory(for: widgetID)
        if fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.removeItem(at: directoryURL)
        }
    }

    private func shouldResetDatabase(after error: Error) -> Bool {
        guard let storageError = error as? WidgetStorageEngineError else {
            return false
        }

        switch storageError {
        case .openFailed(let message), .executeFailed(let message):
            return shouldReset(forDatabaseErrorMessage: message)
        case .prepareFailed,
             .bindFailed,
             .stepFailed,
             .decodeFailed,
             .storageModeMismatch:
            return false
        }
    }

    private func dataDirectory(for widgetID: String) -> URL {
        rootURL
            .appendingPathComponent(widgetID, isDirectory: true)
    }

    private func readStorageMode(at directoryURL: URL) throws -> StorageMode? {
        let modeURL = directoryURL.appendingPathComponent("storage-mode")
        guard fileManager.fileExists(atPath: modeURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: modeURL)
        guard let rawValue = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              let mode = StorageMode(rawValue: rawValue) else {
            throw WidgetStorageEngineError.decodeFailed("Invalid widget storage mode metadata.")
        }

        return mode
    }

    private func writeStorageMode(_ mode: StorageMode, at directoryURL: URL) throws {
        let modeURL = directoryURL.appendingPathComponent("storage-mode")
        try Data(mode.rawValue.utf8).write(to: modeURL, options: .atomic)
    }

    private func shouldReset(forDatabaseErrorMessage message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("database disk image is malformed")
            || normalized.contains("file is not a database")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
