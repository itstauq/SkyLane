import Foundation

private struct WidgetStorageKeyParams: Decodable {
    var key: String
}

private struct WidgetStorageSetParams: Decodable {
    var key: String
    var value: RuntimeJSONValue
}

final class WidgetStorageManager {
    private let fileManager: FileManager
    private let rootURL: URL
    private let storageEngine: WidgetStorageEngine
    private let encryptionEnabled: Bool
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "NotchApp.WidgetStorage")

    init(
        fileManager: FileManager = .default,
        rootURL: URL = WidgetStorageManager.defaultRootURL(),
        secretProvider: WidgetStorageSecretProviding = WidgetStorageKeychain(),
        encryptionEnabled: Bool = Preferences.isWidgetStorageEncryptionEnabled,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL
        self.encryptionEnabled = encryptionEnabled
        self.log = log
        self.storageEngine = WidgetStorageEngine(
            fileManager: fileManager,
            rootURL: rootURL,
            secretProvider: secretProvider,
            encryptionEnabled: encryptionEnabled,
            log: log
        )
    }

    func flushPendingWrites() {
        queue.sync {
            // Wait for previously enqueued writes to drain.
        }
    }

    func handleRPC(
        widgetID: String,
        instanceID: String,
        method: String,
        params: RuntimeJSONValue?
    ) throws -> RuntimeJSONValue {
        switch method {
        case "localStorage.allItems":
            let snapshotResult: RuntimeJSONValue = queue.sync {
                do {
                    return RuntimeJSONValue.object(
                        try storageEngine.allItems(widgetID: widgetID, instanceID: instanceID)
                    )
                } catch {
                    log("Widget storage: failed to load snapshot for \(widgetID)/\(instanceID): \(error.localizedDescription)")
                    return RuntimeJSONValue.null
                }
            }
            return try snapshotResult.mapAllItemsResult()

        case "localStorage.setItem":
            let setParams = try decode(params, as: WidgetStorageSetParams.self)
            try queue.sync {
                try self.storageEngine.setItem(
                    widgetID: widgetID,
                    instanceID: instanceID,
                    key: setParams.key,
                    value: setParams.value
                )
            }
            return .null

        case "localStorage.removeItem":
            let keyParams = try decode(params, as: WidgetStorageKeyParams.self)
            try queue.sync {
                try self.storageEngine.removeItem(widgetID: widgetID, instanceID: instanceID, key: keyParams.key)
            }
            return .null

        default:
            throw RuntimeTransportRPCError(
                code: -32601,
                message: "Unsupported local storage RPC '\(method)'.",
                data: nil
            )
        }
    }

    private func decode<Result: Decodable>(_ value: RuntimeJSONValue?, as type: Result.Type) throws -> Result {
        let data = try JSONEncoder().encode(value ?? .null)
        return try JSONDecoder().decode(type, from: data)
    }

    private static func defaultRootURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("NotchApp", isDirectory: true)
            .appendingPathComponent("WidgetStorage", isDirectory: true)
    }
}

private extension RuntimeJSONValue {
    func mapAllItemsResult() throws -> RuntimeJSONValue {
        if case .null = self {
            throw RuntimeTransportRPCError(
                code: -32020,
                message: "Failed to load local storage snapshot.",
                data: nil
            )
        }

        return self
    }
}
