import CryptoKit
import XCTest

final class WidgetStorageManagerTests: XCTestCase {
    func testStorageSetPersistsAcrossFlushAndReload() throws {
        let (manager, rootURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(3)
            ])
        )

        manager.flushPendingWrites()

        let snapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object(["count": .number(3)]))
    }

    func testStorageSetPersistsAcrossReloadWithoutExplicitFlush() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        do {
            let manager = WidgetStorageManager(
                fileManager: .default,
                rootURL: rootURL,
                secretProvider: TestWidgetStorageSecretProvider(),
                encryptionEnabled: true,
                log: { _ in }
            )

            _ = try manager.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: "localStorage.setItem",
                params: .object([
                    "key": .string("count"),
                    "value": .number(6)
                ])
            )
        }

        let reloadedManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: TestWidgetStorageSecretProvider(),
            encryptionEnabled: true,
            log: { _ in }
        )

        let snapshot = try reloadedManager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object(["count": .number(6)]))
    }

    func testStorageIsolationBetweenInstances() throws {
        let (manager, rootURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let firstInstance = UUID().uuidString
        let secondInstance = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: firstInstance,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(1)
            ])
        )
        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: secondInstance,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(2)
            ])
        )
        manager.flushPendingWrites()

        let firstSnapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: firstInstance,
            method: "localStorage.allItems",
            params: .object([:])
        )
        let secondSnapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: secondInstance,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(firstSnapshot, .object(["count": .number(1)]))
        XCTAssertEqual(secondSnapshot, .object(["count": .number(2)]))
    }

    func testStorageIsolationBetweenWidgets() throws {
        let (manager, rootURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let instanceID = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: "demo.widget",
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(4)
            ])
        )
        _ = try manager.handleRPC(
            widgetID: "other.widget",
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(9)
            ])
        )
        manager.flushPendingWrites()

        let firstSnapshot = try manager.handleRPC(
            widgetID: "demo.widget",
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )
        let secondSnapshot = try manager.handleRPC(
            widgetID: "other.widget",
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(firstSnapshot, .object(["count": .number(4)]))
        XCTAssertEqual(secondSnapshot, .object(["count": .number(9)]))
    }

    func testStorageRemoveDeletesPersistedValue() throws {
        let (manager, rootURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(5)
            ])
        )
        manager.flushPendingWrites()

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.removeItem",
            params: .object([
                "key": .string("count")
            ])
        )
        manager.flushPendingWrites()

        let snapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object([:]))
    }

    func testStorageGetAllReturnsPersistedSnapshot() throws {
        let (manager, rootURL) = makeManager()
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(8)
            ])
        )
        manager.flushPendingWrites()

        let snapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(
            snapshot,
            .object([
                "count": .number(8)
            ])
        )
    }

    func testCorruptDatabaseResetsCleanly() throws {
        let secretProvider = TestWidgetStorageSecretProvider()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        var manager: WidgetStorageManager? = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: secretProvider,
            encryptionEnabled: true,
            log: { _ in }
        )

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        _ = try manager?.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(5)
            ])
        )
        manager?.flushPendingWrites()
        manager = nil

        let dbURL = rootURL
            .appendingPathComponent(widgetID, isDirectory: true)
            .appendingPathComponent("storage.sqlite")
        try Data("not-a-database".utf8).write(to: dbURL, options: .atomic)

        let reloadedManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: secretProvider,
            encryptionEnabled: true,
            log: { _ in }
        )

        let snapshot = try reloadedManager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object([:]))
    }

    func testSnapshotLoadFailureThrowsInsteadOfReturningEmptyStorage() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let manager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: FailingWidgetStorageSecretProvider(),
            encryptionEnabled: true,
            log: { _ in }
        )

        XCTAssertThrowsError(
            try manager.handleRPC(
                widgetID: "demo.widget",
                instanceID: UUID().uuidString,
                method: "localStorage.allItems",
                params: .object([:])
            )
        ) { error in
            let rpcError = error as? RuntimeTransportRPCError
            XCTAssertEqual(rpcError?.code, -32020)
        }
    }

    func testSecretProviderFailureDoesNotDeleteExistingDatabase() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        do {
            let manager = WidgetStorageManager(
                fileManager: .default,
                rootURL: rootURL,
                secretProvider: TestWidgetStorageSecretProvider(),
                encryptionEnabled: true,
                log: { _ in }
            )

            _ = try manager.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: "localStorage.setItem",
                params: .object([
                    "key": .string("count"),
                    "value": .number(11)
                ])
            )
            manager.flushPendingWrites()
        }

        let dbURL = rootURL
            .appendingPathComponent(widgetID, isDirectory: true)
            .appendingPathComponent("storage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let failingManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: FailingWidgetStorageSecretProvider(),
            encryptionEnabled: true,
            log: { _ in }
        )

        XCTAssertThrowsError(
            try failingManager.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: "localStorage.allItems",
                params: .object([:])
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let recoveredManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: TestWidgetStorageSecretProvider(),
            encryptionEnabled: true,
            log: { _ in }
        )

        let snapshot = try recoveredManager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object(["count": .number(11)]))
    }

    func testEncryptionModeMismatchDoesNotDeleteExistingDatabase() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        do {
            let manager = WidgetStorageManager(
                fileManager: .default,
                rootURL: rootURL,
                secretProvider: TestWidgetStorageSecretProvider(),
                encryptionEnabled: false,
                log: { _ in }
            )

            _ = try manager.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: "localStorage.setItem",
                params: .object([
                    "key": .string("count"),
                    "value": .number(13)
                ])
            )
        }

        let dbURL = rootURL
            .appendingPathComponent(widgetID, isDirectory: true)
            .appendingPathComponent("storage.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let mismatchedManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: TestWidgetStorageSecretProvider(),
            encryptionEnabled: true,
            log: { _ in }
        )

        XCTAssertThrowsError(
            try mismatchedManager.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: "localStorage.allItems",
                params: .object([:])
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let recoveredManager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: TestWidgetStorageSecretProvider(),
            encryptionEnabled: false,
            log: { _ in }
        )

        let snapshot = try recoveredManager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object(["count": .number(13)]))
    }
}

private func makeManager() -> (WidgetStorageManager, URL) {
    let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let manager = WidgetStorageManager(
        fileManager: .default,
        rootURL: rootURL,
        secretProvider: TestWidgetStorageSecretProvider(),
        encryptionEnabled: true,
        log: { _ in }
    )

    return (manager, rootURL)
}

extension WidgetStorageManagerTests {
    func testStorageWorksWhenEncryptionIsDisabled() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let manager = WidgetStorageManager(
            fileManager: .default,
            rootURL: rootURL,
            secretProvider: FailingWidgetStorageSecretProvider(),
            encryptionEnabled: false,
            log: { _ in }
        )

        let widgetID = "demo.widget"
        let instanceID = UUID().uuidString

        _ = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.setItem",
            params: .object([
                "key": .string("count"),
                "value": .number(21)
            ])
        )
        manager.flushPendingWrites()

        let snapshot = try manager.handleRPC(
            widgetID: widgetID,
            instanceID: instanceID,
            method: "localStorage.allItems",
            params: .object([:])
        )

        XCTAssertEqual(snapshot, .object(["count": .number(21)]))
    }
}

private final class TestWidgetStorageSecretProvider: WidgetStorageSecretProviding {
    private let master = Data(repeating: 0x42, count: 32)

    func masterKey() throws -> Data {
        master
    }

    func key(for widgetID: String) throws -> Data {
        let derived = HMAC<SHA256>.authenticationCode(
            for: Data(widgetID.utf8),
            using: SymmetricKey(data: master)
        )
        return Data(derived)
    }
}

private struct FailingWidgetStorageSecretProvider: WidgetStorageSecretProviding {
    func masterKey() throws -> Data {
        throw TestSecretError.unavailable
    }

    func key(for widgetID: String) throws -> Data {
        throw TestSecretError.unavailable
    }
}

private enum TestSecretError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Test secret provider unavailable."
    }
}
