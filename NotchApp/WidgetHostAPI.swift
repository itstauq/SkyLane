import AppKit
import Foundation

private let cameraDevicePreferenceName = "cameraDeviceId"

struct RuntimeFetchRequestParams: Decodable {
    var requestId: String
    var url: String
    var method: String?
    var headers: [String: String]?
    var body: String?
    var bodyEncoding: String?
}

struct RuntimeFetchResponsePayload: Encodable, Equatable {
    var status: Int
    var statusText: String
    var headers: [String: String]
    var body: String?
    var bodyEncoding: String
}

struct RuntimeCancelRequestParams: Decodable {
    var requestId: String
}

struct RuntimeBrowserOpenParams: Decodable {
    var url: String
}

struct RuntimeCameraSelectDeviceParams: Decodable {
    var id: String
}

struct RuntimeSetPreferenceValueParams: Decodable {
    var name: String
    var value: RuntimeJSONValue?
}

struct RuntimeRPCRequestParams: Decodable {
    var instanceId: String
    var sessionId: String
    var method: String
    var params: RuntimeJSONValue?
}

struct RuntimeRPCResponsePayload: Encodable {
    var sessionId: String
    var value: RuntimeJSONValue
}

protocol WidgetHostLocalStorageHandling {
    func handleRPC(
        widgetID: String,
        instanceID: String,
        method: String,
        params: RuntimeJSONValue?
    ) throws -> RuntimeJSONValue

    func setPreferenceValue(
        widgetID: String,
        instanceID: String,
        name: String,
        value: RuntimeJSONValue?
    ) throws

    func preferenceValues(
        widgetID: String,
        instanceID: String
    ) -> [String: RuntimeJSONValue]
}

extension WidgetStorageManager: WidgetHostLocalStorageHandling {}

protocol WidgetHostNetworkDataTask: AnyObject {
    func resume()
    func cancel()
}

extension URLSessionDataTask: WidgetHostNetworkDataTask {}

enum WidgetHostNetworkRequestKind {
    case fetch
    case openURL
    case image
}

struct WidgetHostNetworkContext {
    var widgetID: String
    var instanceID: String
    var kind: WidgetHostNetworkRequestKind
}

private enum WidgetHostNetworkPolicyError: Error {
    case invalidURL
    case disallowedScheme
}

enum WidgetHostNetworkPolicy {
    static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return scheme == "https"
    }

    static func validate(_ url: URL, context: WidgetHostNetworkContext) throws {
        guard allows(url) else {
            throw WidgetHostNetworkPolicyError.disallowedScheme
        }
    }

    static func validatedURL(from rawValue: String, context: WidgetHostNetworkContext) throws -> URL {
        guard let url = URL(string: rawValue) else {
            throw rpcError(for: .invalidURL, context: context)
        }

        do {
            try validate(url, context: context)
        } catch let error as WidgetHostNetworkPolicyError {
            throw rpcError(for: error, context: context)
        } catch {
            throw error
        }

        return url
    }

    static func validateResolvedURL(_ url: URL, context: WidgetHostNetworkContext) throws {
        do {
            try validate(url, context: context)
        } catch let error as WidgetHostNetworkPolicyError {
            throw rpcError(for: error, context: context)
        } catch {
            throw error
        }
    }

    private static func rpcError(
        for error: WidgetHostNetworkPolicyError,
        context: WidgetHostNetworkContext
    ) -> RuntimeTransportRPCError {
        switch error {
        case .invalidURL, .disallowedScheme:
            return RuntimeTransportRPCError(
                code: -32010,
                message: validationMessage(for: context.kind),
                data: nil
            )
        }
    }

    private static func validationMessage(for kind: WidgetHostNetworkRequestKind) -> String {
        let scope: String
        switch kind {
        case .fetch:
            scope = "fetch URLs"
        case .openURL:
            scope = "URLs can be opened"
        case .image:
            scope = "image URLs are allowed"
        }

        return "Only https \(scope)."
    }
}

@MainActor
protocol WidgetHostNetworkHandling {
    func fetch(
        _ params: RuntimeFetchRequestParams,
        context: WidgetHostNetworkContext
    ) async throws -> RuntimeFetchResponsePayload
    func cancel(_ params: RuntimeCancelRequestParams)
    func open(
        _ params: RuntimeBrowserOpenParams,
        context: WidgetHostNetworkContext
    ) throws
}

@MainActor
final class WidgetHostNetworkService: WidgetHostNetworkHandling {
    typealias DataTaskFactory = (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> WidgetHostNetworkDataTask

    private let makeDataTask: DataTaskFactory?
    private let fetchLoader: WidgetHostFetchDataLoader?
    private let openURLAction: (URL) -> Bool
    private var pendingFetchTasks: [String: WidgetHostNetworkDataTask] = [:]

    init(
        makeDataTask: @escaping DataTaskFactory,
        openURLAction: @escaping (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.makeDataTask = makeDataTask
        self.fetchLoader = nil
        self.openURLAction = openURLAction
    }

    init(
        protocolClasses: [AnyClass]? = nil,
        openURLAction: @escaping (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.makeDataTask = nil
        self.fetchLoader = WidgetHostFetchDataLoader(protocolClasses: protocolClasses)
        self.openURLAction = openURLAction
    }

    func fetch(
        _ params: RuntimeFetchRequestParams,
        context: WidgetHostNetworkContext
    ) async throws -> RuntimeFetchResponsePayload {
        let url = try WidgetHostNetworkPolicy.validatedURL(from: params.url, context: context)

        var request = URLRequest(url: url)
        request.httpMethod = params.method?.isEmpty == false ? params.method : "GET"
        for (header, value) in params.headers ?? [:] {
            request.setValue(value, forHTTPHeaderField: header)
        }

        if let body = params.body {
            if params.bodyEncoding == "base64" {
                guard let decoded = Data(base64Encoded: body) else {
                    throw RuntimeTransportRPCError(
                        code: -32602,
                        message: "Invalid base64 fetch body.",
                        data: nil
                    )
                }
                request.httpBody = decoded
            } else {
                request.httpBody = Data(body.utf8)
            }
        }

        return try await performFetch(requestId: params.requestId, request: request, context: context)
    }

    func cancel(_ params: RuntimeCancelRequestParams) {
        pendingFetchTasks.removeValue(forKey: params.requestId)?.cancel()
    }

    func open(
        _ params: RuntimeBrowserOpenParams,
        context: WidgetHostNetworkContext
    ) throws {
        let url = try WidgetHostNetworkPolicy.validatedURL(from: params.url, context: context)

        guard openURLAction(url) else {
            throw RuntimeTransportRPCError(
                code: -32011,
                message: "Failed to open URL.",
                data: nil
            )
        }
    }

    private func performFetch(
        requestId: String,
        request: URLRequest,
        context: WidgetHostNetworkContext
    ) async throws -> RuntimeFetchResponsePayload {
        try await withCheckedThrowingContinuation { continuation in
            let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { [weak self] data, response, error in
                Task { @MainActor [weak self] in
                    self?.pendingFetchTasks.removeValue(forKey: requestId)

                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.resume(
                            throwing: RuntimeTransportRPCError(
                                code: -32012,
                                message: "Invalid fetch response.",
                                data: nil
                            )
                        )
                        return
                    }

                    do {
                        let resolvedURL = httpResponse.url ?? request.url
                        if let resolvedURL {
                            try WidgetHostNetworkPolicy.validateResolvedURL(resolvedURL, context: context)
                        }

                        let payload = try self?.makeFetchResponsePayload(
                            statusCode: httpResponse.statusCode,
                            headers: httpResponse.allHeaderFields,
                            data: data ?? Data(),
                            mimeType: httpResponse.mimeType
                        ) ?? RuntimeFetchResponsePayload(
                            status: httpResponse.statusCode,
                            statusText: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                            headers: [:],
                            body: nil,
                            bodyEncoding: "text"
                        )
                        continuation.resume(returning: payload)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }

            let task: WidgetHostNetworkDataTask
            if let fetchLoader {
                task = fetchLoader.dataTask(with: request, context: context, completion: completion)
            } else if let makeDataTask {
                task = makeDataTask(request, completion)
            } else {
                continuation.resume(
                    throwing: RuntimeTransportRPCError(
                        code: -32012,
                        message: "Unable to start fetch request.",
                        data: nil
                    )
                )
                return
            }

            pendingFetchTasks[requestId] = task
            task.resume()
        }
    }

    private func makeFetchResponsePayload(
        statusCode: Int,
        headers: [AnyHashable: Any],
        data: Data,
        mimeType: String?
    ) throws -> RuntimeFetchResponsePayload {
        let normalizedHeaders = headers.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }

        let isTextResponse = mimeType?.hasPrefix("text/") == true || mimeType == "application/json"
        if isTextResponse, let text = String(data: data, encoding: .utf8) {
            return RuntimeFetchResponsePayload(
                status: statusCode,
                statusText: HTTPURLResponse.localizedString(forStatusCode: statusCode),
                headers: normalizedHeaders,
                body: text,
                bodyEncoding: "text"
            )
        }

        return RuntimeFetchResponsePayload(
            status: statusCode,
            statusText: HTTPURLResponse.localizedString(forStatusCode: statusCode),
            headers: normalizedHeaders,
            body: data.isEmpty ? nil : data.base64EncodedString(),
            bodyEncoding: "base64"
        )
    }
}

private final class WidgetHostFetchDataLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Handler: @unchecked Sendable {
        let context: WidgetHostNetworkContext
        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void
        var terminalError: Error?
        var data = Data()
        var response: URLResponse?

        init(
            context: WidgetHostNetworkContext,
            completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
        ) {
            self.context = context
            self.completion = completion
        }
    }

    private let stateLock = NSLock()
    private var handlers: [Int: Handler] = [:]
    private var session: URLSession!

    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.default
        configuration.protocolClasses = protocolClasses

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session.sessionDescription = "Widget Host Fetch URLSession"
    }

    deinit {
        session.invalidateAndCancel()
    }

    func dataTask(
        with request: URLRequest,
        context: WidgetHostNetworkContext,
        completion: @escaping @Sendable (Data?, URLResponse?, Error?) -> Void
    ) -> WidgetHostNetworkDataTask {
        let task = session.dataTask(with: request)

        withHandlerLock {
            handlers[task.taskIdentifier] = Handler(context: context, completion: completion)
        }

        return task
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handler(for: dataTask.taskIdentifier) else {
            completionHandler(.cancel)
            return
        }

        handler.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask.taskIdentifier) else {
            return
        }

        handler.data.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let handler = handler(for: task.taskIdentifier),
              let url = request.url else {
            completionHandler(nil)
            return
        }

        do {
            try WidgetHostNetworkPolicy.validateResolvedURL(url, context: handler.context)
            completionHandler(request)
        } catch {
            handler.terminalError = error
            task.cancel()
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let handler = removeHandler(for: task.taskIdentifier) else {
            return
        }

        handler.completion(handler.data, handler.response, handler.terminalError ?? error)
    }

    private func handler(for taskIdentifier: Int) -> Handler? {
        withHandlerLock {
            handlers[taskIdentifier]
        }
    }

    private func removeHandler(for taskIdentifier: Int) -> Handler? {
        withHandlerLock {
            handlers.removeValue(forKey: taskIdentifier)
        }
    }

    private func withHandlerLock<T>(_ work: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return work()
    }
}

@MainActor
final class WidgetHostAPI {
    private let sessionManager: WidgetSessionManager
    private let storage: WidgetHostLocalStorageHandling
    private let network: WidgetHostNetworkHandling
    private let resolveWidgetID: (UUID) -> String?
    private let log: (String) -> Void
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    init(
        sessionManager: WidgetSessionManager,
        storage: WidgetHostLocalStorageHandling,
        network: WidgetHostNetworkHandling,
        resolveWidgetID: @escaping (UUID) -> String?,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.sessionManager = sessionManager
        self.storage = storage
        self.network = network
        self.resolveWidgetID = resolveWidgetID
        self.log = log
    }

    func handle(_ request: RuntimeTransportRequest) async throws -> RuntimeJSONValue? {
        guard request.method == "rpc" else {
            throw RuntimeTransportRPCError(
                code: -32601,
                message: "Unsupported runtime request '\(request.method)'.",
                data: nil
            )
        }

        let rpcRequest: RuntimeRPCRequestParams
        do {
            rpcRequest = try decode(request.params, as: RuntimeRPCRequestParams.self)
        } catch {
            throw RuntimeTransportRPCError(
                code: -32602,
                message: "Invalid runtime RPC params: \(error.localizedDescription)",
                data: nil
            )
        }

        guard let instanceID = UUID(uuidString: rpcRequest.instanceId) else {
            throw RuntimeTransportRPCError(
                code: -32001,
                message: "Unknown widget instance '\(rpcRequest.instanceId)'.",
                data: nil
            )
        }

        guard let widgetID = resolveWidgetID(instanceID) else {
            throw RuntimeTransportRPCError(
                code: -32001,
                message: "Unknown widget instance '\(rpcRequest.instanceId)'.",
                data: nil
            )
        }

        guard sessionManager.acceptsWorkerSession(instanceID: instanceID, sessionId: rpcRequest.sessionId) else {
            throw RuntimeTransportRPCError(
                code: -32004,
                message: "Session mismatch for instance '\(rpcRequest.instanceId)'.",
                data: nil
            )
        }

        let value: RuntimeJSONValue
        do {
            value = try await route(
                widgetID: widgetID,
                instanceID: rpcRequest.instanceId,
                method: rpcRequest.method,
                params: rpcRequest.params
            )
        } catch let rpcError as RuntimeTransportRPCError {
            throw rpcError
        } catch {
            log("Widget host API: \(rpcRequest.method) failed for \(rpcRequest.instanceId): \(error.localizedDescription)")
            throw RuntimeTransportRPCError(
                code: -32000,
                message: error.localizedDescription,
                data: nil
            )
        }

        return try encodeRuntimeJSONValue(
            RuntimeRPCResponsePayload(
                sessionId: rpcRequest.sessionId,
                value: value
            )
        )
    }

    private func route(
        widgetID: String,
        instanceID: String,
        method: String,
        params: RuntimeJSONValue?
    ) async throws -> RuntimeJSONValue {
        switch method {
        case "localStorage.allItems", "localStorage.setItem", "localStorage.removeItem":
            return try storage.handleRPC(
                widgetID: widgetID,
                instanceID: instanceID,
                method: method,
                params: params
            )
        case "network.fetch":
            let fetchParams = try decode(params, as: RuntimeFetchRequestParams.self)
            let context = WidgetHostNetworkContext(
                widgetID: widgetID,
                instanceID: instanceID,
                kind: .fetch
            )
            return try encodeRuntimeJSONValue(try await network.fetch(fetchParams, context: context))
        case "request.cancel":
            let cancelParams = try decode(params, as: RuntimeCancelRequestParams.self)
            network.cancel(cancelParams)
            return .null
        case "browser.open":
            let openParams = try decode(params, as: RuntimeBrowserOpenParams.self)
            let context = WidgetHostNetworkContext(
                widgetID: widgetID,
                instanceID: instanceID,
                kind: .openURL
            )
            try network.open(openParams, context: context)
            return .null
        case "preferences.setValue":
            let preferenceParams = try decode(params, as: RuntimeSetPreferenceValueParams.self)
            try storage.setPreferenceValue(
                widgetID: widgetID,
                instanceID: instanceID,
                name: preferenceParams.name,
                value: preferenceParams.value
            )
            if let uuid = UUID(uuidString: instanceID) {
                NotificationCenter.default.post(
                    name: .widgetPreferencesDidChange,
                    object: WidgetPreferencesDidChangePayload(instanceID: uuid)
                )
            }
            return .null
        case "camera.listDevices":
            let selectedCameraID = resolvedPreferenceValues(
                widgetID: widgetID,
                instanceID: instanceID
            )[cameraDevicePreferenceName]?.stringValue
            return try encodeRuntimeJSONValue(
                WidgetCameraRegistry.shared.availableDevices(selectedDeviceID: selectedCameraID)
            )
        case "camera.selectDevice":
            let cameraParams = try decode(params, as: RuntimeCameraSelectDeviceParams.self)
            try storage.setPreferenceValue(
                widgetID: widgetID,
                instanceID: instanceID,
                name: cameraDevicePreferenceName,
                value: RuntimeJSONValue.string(cameraParams.id)
            )
            if let uuid = UUID(uuidString: instanceID) {
                NotificationCenter.default.post(
                    name: .widgetPreferencesDidChange,
                    object: WidgetPreferencesDidChangePayload(instanceID: uuid)
                )
            }
            return .null
        default:
            throw RuntimeTransportRPCError(
                code: -32601,
                message: "Unsupported widget host RPC '\(method)'.",
                data: nil
            )
        }
    }

    private func decode<Result: Decodable>(_ value: RuntimeJSONValue?, as type: Result.Type) throws -> Result {
        let data = try jsonEncoder.encode(value ?? .null)
        return try jsonDecoder.decode(type, from: data)
    }

    private func encodeRuntimeJSONValue<Result: Encodable>(_ value: Result) throws -> RuntimeJSONValue {
        let data = try jsonEncoder.encode(value)
        return try jsonDecoder.decode(RuntimeJSONValue.self, from: data)
    }

    private func resolvedPreferenceValues(
        widgetID: String,
        instanceID: String
    ) -> [String: RuntimeJSONValue] {
        guard let storage = storage as? WidgetStorageManager else {
            return storage.preferenceValues(widgetID: widgetID, instanceID: instanceID)
        }

        let viewManager = ViewManager()
        let preferences = viewManager.definition(for: widgetID)?.preferences ?? []
        let storagePreferences = preferences.map {
            WidgetStoragePreferenceDefinition(
                name: $0.name,
                kind: storagePreferenceKind(for: $0.type),
                isRequired: $0.isRequired,
                defaultValue: $0.defaultValue
            )
        }

        return storage.resolvedPreferenceValues(
            widgetID: widgetID,
            preferences: storagePreferences,
            instanceID: instanceID
        )
    }

    private func storagePreferenceKind(for type: WidgetPreferenceType) -> WidgetStoragePreferenceKind {
        switch type {
        case .textfield:
            return .text
        case .password:
            return .password
        case .checkbox:
            return .checkbox
        case .dropdown:
            return .dropdown
        case .camera:
            return .camera
        }
    }
}
