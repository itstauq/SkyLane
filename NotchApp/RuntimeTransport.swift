import Foundation

enum RuntimeJSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: RuntimeJSONValue])
    case array([RuntimeJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let object = try? container.decode([String: RuntimeJSONValue].self) {
            self = .object(object)
        } else if let array = try? container.decode([RuntimeJSONValue].self) {
            self = .array(array)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    func decode<Result: Decodable>(as type: Result.Type, using decoder: JSONDecoder = JSONDecoder()) throws -> Result {
        let data = try JSONEncoder().encode(self)
        return try decoder.decode(Result.self, from: data)
    }
}

struct RuntimeTransportProcessConfiguration {
    var executableURL: URL
    var arguments: [String]
    var currentDirectoryURL: URL
}

struct RuntimeTransportNotification {
    var method: String
    var params: RuntimeJSONValue?
}

struct RuntimeTransportRequest {
    var id: String
    var method: String
    var params: RuntimeJSONValue?
}

struct RuntimeTransportRPCError: Error, Codable {
    var code: Int
    var message: String
    var data: RuntimeJSONValue?
}

extension RuntimeTransportRPCError: LocalizedError {
    var errorDescription: String? {
        "Runtime RPC error \(code): \(message)"
    }
}

private struct RuntimeTransportRequestEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    var id: String
    var method: String
    var params: Params?
}

private struct RuntimeTransportNotificationEnvelope<Params: Encodable>: Encodable {
    let jsonrpc = "2.0"
    var method: String
    var params: Params?
}

private struct RuntimeTransportIncomingMessage: Decodable {
    var jsonrpc: String?
    var id: String?
    var method: String?
    var params: RuntimeJSONValue?
    var result: RuntimeJSONValue?
    var error: RuntimeTransportRPCError?
}

private struct RuntimeTransportResponseEnvelope: Encodable {
    let jsonrpc = "2.0"
    var id: String
    var result: RuntimeJSONValue
}

private struct RuntimeTransportErrorEnvelope: Encodable {
    let jsonrpc = "2.0"
    var id: String
    var error: RuntimeTransportRPCError
}

private struct RuntimeTransportNoParams: Encodable {}

@MainActor
final class RuntimeTransport {
    var notificationHandler: ((RuntimeTransportNotification) -> Void)?
    var requestHandler: ((RuntimeTransportRequest) async throws -> RuntimeJSONValue?)?
    var stderrHandler: ((String) -> Void)?
    var terminationHandler: ((String) -> Void)?

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutBuffer = Data()
    private var stderrBuffer = Data()
    private var pending: [String: CheckedContinuation<RuntimeJSONValue?, Error>] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var isRunning: Bool {
        process?.isRunning == true && stdinHandle != nil
    }

    func ensureStarted(configuration: RuntimeTransportProcessConfiguration) throws {
        if isRunning {
            return
        }

        let newProcess = Process()
        newProcess.executableURL = configuration.executableURL
        newProcess.arguments = configuration.arguments
        newProcess.currentDirectoryURL = configuration.currentDirectoryURL

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        newProcess.standardInput = stdinPipe
        newProcess.standardOutput = stdoutPipe
        newProcess.standardError = stderrPipe
        newProcess.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination(process)
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Task { @MainActor [weak self] in
                self?.appendStdout(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            Task { @MainActor [weak self] in
                self?.appendStderr(data)
            }
        }

        try newProcess.run()
        process = newProcess
        stdinHandle = stdinPipe.fileHandleForWriting
    }

    func sendRequest<Params: Encodable>(
        _ method: String,
        params: Params? = nil,
        configuration: RuntimeTransportProcessConfiguration
    ) async throws -> RuntimeJSONValue? {
        try ensureStarted(configuration: configuration)

        let requestID = UUID().uuidString
        let data = try encoder.encode(
            RuntimeTransportRequestEnvelope(
                id: requestID,
                method: method,
                params: params
            )
        )
        var line = data
        line.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pending[requestID] = continuation

            do {
                try writeLine(line)
            } catch {
                pending.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    func sendNotification<Params: Encodable>(
        _ method: String,
        params: Params? = nil,
        configuration: RuntimeTransportProcessConfiguration
    ) throws {
        try ensureStarted(configuration: configuration)
        try sendNotificationIfRunning(method, params: params)
    }

    func sendBestEffortNotificationIfRunning(_ method: String) {
        do {
            try sendNotificationIfRunning(method, params: Optional<RuntimeTransportNoParams>.none)
        } catch {
            stderrHandler?("Widget runtime notification write failed: \(error.localizedDescription)")
        }
    }

    private func sendNotificationIfRunning<Params: Encodable>(_ method: String, params: Params?) throws {
        guard isRunning else {
            return
        }

        let data = try encoder.encode(
            RuntimeTransportNotificationEnvelope(
                method: method,
                params: params
            )
        )
        var line = data
        line.append(0x0A)
        try writeLine(line)
    }

    private func sendResponse(id: String, result: RuntimeJSONValue?) throws {
        let data = try encoder.encode(
            RuntimeTransportResponseEnvelope(
                id: id,
                result: result ?? .null
            )
        )
        var line = data
        line.append(0x0A)
        try writeLine(line)
    }

    private func sendErrorResponse(id: String, error: RuntimeTransportRPCError) throws {
        let data = try encoder.encode(
            RuntimeTransportErrorEnvelope(
                id: id,
                error: error
            )
        )
        var line = data
        line.append(0x0A)
        try writeLine(line)
    }

    private func writeLine(_ data: Data) throws {
        guard let stdinHandle else {
            throw NSError(
                domain: "NotchWidgetRuntime",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Widget runtime stdin unavailable."]
            )
        }

        try stdinHandle.write(contentsOf: data)
    }

    private func handleProcessTermination(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }

        let status = terminatedProcess.terminationStatus
        let reason = terminatedProcess.terminationReason
        let description = "Widget runtime exited unexpectedly (reason: \(reason.rawValue), status: \(status))."

        stdoutBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
        stdinHandle = nil
        process = nil

        let error = NSError(
            domain: "NotchWidgetRuntime",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: description]
        )
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }

        terminationHandler?(description)
    }

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        drainStdout()
    }

    private func appendStderr(_ data: Data) {
        stderrBuffer.append(data)
        while let range = stderrBuffer.range(of: Data([0x0A])) {
            let lineData = stderrBuffer.subdata(in: 0..<range.lowerBound)
            stderrBuffer.removeSubrange(0...range.lowerBound)
            let line = String(decoding: lineData, as: UTF8.self)
            if !line.isEmpty {
                stderrHandler?(line)
            }
        }
    }

    private func drainStdout() {
        while let range = stdoutBuffer.range(of: Data([0x0A])) {
            let lineData = stdoutBuffer.subdata(in: 0..<range.lowerBound)
            stdoutBuffer.removeSubrange(0...range.lowerBound)
            guard !lineData.isEmpty else { continue }

            do {
                let message = try decoder.decode(RuntimeTransportIncomingMessage.self, from: lineData)
                handle(message)
            } catch {
                let line = String(decoding: lineData, as: UTF8.self)
                stderrHandler?("Widget helper decode error: \(line)")
            }
        }
    }

    private func handle(_ message: RuntimeTransportIncomingMessage) {
        if let method = message.method {
            if let requestID = message.id {
                let request = RuntimeTransportRequest(
                    id: requestID,
                    method: method,
                    params: message.params
                )

                Task { @MainActor [weak self] in
                    guard let self else { return }

                    guard let requestHandler = self.requestHandler else {
                        do {
                            try self.sendErrorResponse(
                                id: request.id,
                                error: RuntimeTransportRPCError(
                                    code: -32601,
                                    message: "Unsupported runtime request '\(request.method)'.",
                                    data: nil
                                )
                            )
                        } catch {
                            self.stderrHandler?("Widget runtime response write failed: \(error.localizedDescription)")
                        }
                        return
                    }

                    do {
                        let result = try await requestHandler(request)
                        try self.sendResponse(id: request.id, result: result)
                    } catch let rpcError as RuntimeTransportRPCError {
                        do {
                            try self.sendErrorResponse(id: request.id, error: rpcError)
                        } catch {
                            self.stderrHandler?("Widget runtime response write failed: \(error.localizedDescription)")
                        }
                    } catch {
                        do {
                            try self.sendErrorResponse(
                                id: request.id,
                                error: RuntimeTransportRPCError(
                                    code: -32000,
                                    message: error.localizedDescription,
                                    data: nil
                                )
                            )
                        } catch {
                            self.stderrHandler?("Widget runtime response write failed: \(error.localizedDescription)")
                        }
                    }
                }
                return
            }

            notificationHandler?(RuntimeTransportNotification(method: method, params: message.params))
            return
        }

        guard let requestID = message.id,
              let continuation = pending.removeValue(forKey: requestID) else {
            return
        }

        if let error = message.error {
            continuation.resume(throwing: error)
            return
        }

        continuation.resume(returning: message.result)
    }
}
