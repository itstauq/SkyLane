import AppKit
import Foundation

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
}

extension WidgetStorageManager: WidgetHostLocalStorageHandling {}

protocol WidgetHostNetworkDataTask: AnyObject {
    func resume()
    func cancel()
}

extension URLSessionDataTask: WidgetHostNetworkDataTask {}

@MainActor
protocol WidgetHostNetworkHandling {
    func fetch(_ params: RuntimeFetchRequestParams) async throws -> RuntimeFetchResponsePayload
    func cancel(_ params: RuntimeCancelRequestParams)
    func open(_ params: RuntimeBrowserOpenParams) throws
}

@MainActor
final class WidgetHostNetworkService: WidgetHostNetworkHandling {
    typealias DataTaskFactory = (URLRequest, @escaping @Sendable (Data?, URLResponse?, Error?) -> Void) -> WidgetHostNetworkDataTask

    private let makeDataTask: DataTaskFactory
    private let openURLAction: (URL) -> Bool
    private var pendingFetchTasks: [String: WidgetHostNetworkDataTask] = [:]

    init(
        makeDataTask: @escaping DataTaskFactory = { request, completion in
            URLSession.shared.dataTask(with: request, completionHandler: completion)
        },
        openURLAction: @escaping (URL) -> Bool = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.makeDataTask = makeDataTask
        self.openURLAction = openURLAction
    }

    func fetch(_ params: RuntimeFetchRequestParams) async throws -> RuntimeFetchResponsePayload {
        guard let url = URL(string: params.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw RuntimeTransportRPCError(
                code: -32010,
                message: "Only http and https fetch URLs are allowed.",
                data: nil
            )
        }

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

        return try await performFetch(requestId: params.requestId, request: request)
    }

    func cancel(_ params: RuntimeCancelRequestParams) {
        pendingFetchTasks.removeValue(forKey: params.requestId)?.cancel()
    }

    func open(_ params: RuntimeBrowserOpenParams) throws {
        guard let url = URL(string: params.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw RuntimeTransportRPCError(
                code: -32010,
                message: "Only http and https URLs can be opened.",
                data: nil
            )
        }

        guard openURLAction(url) else {
            throw RuntimeTransportRPCError(
                code: -32011,
                message: "Failed to open URL.",
                data: nil
            )
        }
    }

    private func performFetch(requestId: String, request: URLRequest) async throws -> RuntimeFetchResponsePayload {
        try await withCheckedThrowingContinuation { continuation in
            let task = makeDataTask(request) { [weak self] data, response, error in
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
            return try encodeRuntimeJSONValue(try await network.fetch(fetchParams))
        case "request.cancel":
            let cancelParams = try decode(params, as: RuntimeCancelRequestParams.self)
            network.cancel(cancelParams)
            return .null
        case "browser.open":
            let openParams = try decode(params, as: RuntimeBrowserOpenParams.self)
            try network.open(openParams)
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
}
