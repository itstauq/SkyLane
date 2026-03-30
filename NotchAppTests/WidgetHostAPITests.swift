import Foundation
import XCTest

@MainActor
final class WidgetHostAPITests: XCTestCase {
    func testNetworkServiceRejectsFileURLs() async {
        let service = WidgetHostNetworkService(
            makeDataTask: { _, _ in
                XCTFail("Fetch factory should not be called for rejected schemes")
                return TestNetworkDataTask()
            }
        )

        do {
            _ = try await service.fetch(
                RuntimeFetchRequestParams(
                    requestId: "req-1",
                    url: "file:///tmp/demo.txt",
                    method: "GET",
                    headers: nil,
                    body: nil,
                    bodyEncoding: nil
                )
            )
            XCTFail("Expected file:// fetch to be rejected")
        } catch let error as RuntimeTransportRPCError {
            XCTAssertEqual(error.code, -32010)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkServiceReturnsJSONTextPayload() async throws {
        let task = TestNetworkDataTask()
        var capturedRequest: URLRequest?
        let service = WidgetHostNetworkService(
            makeDataTask: { request, completion in
                capturedRequest = request
                task.completion = completion
                return task
            }
        )

        let fetchTask = Task {
            try await service.fetch(
                RuntimeFetchRequestParams(
                    requestId: "req-2",
                    url: "https://example.com/data",
                    method: "POST",
                    headers: ["content-type": "application/json"],
                    body: "{\"hello\":true}",
                    bodyEncoding: "text"
                )
            )
        }

        await Task.yield()
        XCTAssertTrue(task.didResume)
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(String(data: capturedRequest?.httpBody ?? Data(), encoding: .utf8), "{\"hello\":true}")

        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/data")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        task.complete(data: Data("{\"ok\":true}".utf8), response: response, error: nil)

        let payload = try await fetchTask.value
        XCTAssertEqual(payload.status, 200)
        XCTAssertEqual(payload.body, "{\"ok\":true}")
        XCTAssertEqual(payload.bodyEncoding, "text")
        XCTAssertEqual(payload.headers["Content-Type"], "application/json")
    }

    func testNetworkServiceCancelCancelsPendingFetchTask() async {
        let task = TestNetworkDataTask()
        let service = WidgetHostNetworkService(
            makeDataTask: { _, completion in
                task.completion = completion
                return task
            }
        )

        let fetchTask = Task {
            try await service.fetch(
                RuntimeFetchRequestParams(
                    requestId: "req-3",
                    url: "https://example.com/slow",
                    method: "GET",
                    headers: nil,
                    body: nil,
                    bodyEncoding: nil
                )
            )
        }

        await Task.yield()
        service.cancel(RuntimeCancelRequestParams(requestId: "req-3"))
        XCTAssertTrue(task.didCancel)

        do {
            _ = try await fetchTask.value
            XCTFail("Expected cancelled fetch to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        }
    }

    func testNetworkServiceOpenRejectsTelScheme() {
        let service = WidgetHostNetworkService(openURLAction: { _ in
            XCTFail("openURLAction should not be called for rejected schemes")
            return false
        })

        XCTAssertThrowsError(
            try service.open(RuntimeBrowserOpenParams(url: "tel:123"))
        ) { error in
            XCTAssertEqual((error as? RuntimeTransportRPCError)?.code, -32010)
        }
    }

    func testNetworkServiceOpenAcceptsHTTPS() throws {
        var openedURL: URL?
        let service = WidgetHostNetworkService(openURLAction: { url in
            openedURL = url
            return true
        })

        try service.open(RuntimeBrowserOpenParams(url: "https://example.com"))
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com")
    }

    func testHandleRoutesStorageRPCThroughWidgetHostAPI() async throws {
        let sessionManager = WidgetSessionManager()
        let storage = TestStorageHandler(result: .object(["count": .number(1)]))
        let network = TestNetworkHandler()
        let instanceID = UUID()
        sessionManager.beginMount(instanceID: instanceID)

        let api = WidgetHostAPI(
            sessionManager: sessionManager,
            storage: storage,
            network: network,
            resolveWidgetID: { id in
                id == instanceID ? "demo.widget" : nil
            }
        )

        let response = try await api.handle(
            RuntimeTransportRequest(
                id: "1",
                method: "rpc",
                params: .object([
                    "instanceId": .string(instanceID.uuidString),
                    "sessionId": .string("session-1"),
                    "method": .string("localStorage.allItems"),
                    "params": .object([:])
                ])
            )
        )

        XCTAssertEqual(storage.lastWidgetID, "demo.widget")
        XCTAssertEqual(storage.lastInstanceID, instanceID.uuidString)
        XCTAssertEqual(storage.lastMethod, "localStorage.allItems")
        XCTAssertEqual(
            response,
            .object([
                "sessionId": .string("session-1"),
                "value": .object(["count": .number(1)])
            ])
        )
    }

    func testHandleRejectsUnknownWidgetHostRPCMethod() async {
        let sessionManager = WidgetSessionManager()
        let storage = TestStorageHandler(result: .null)
        let network = TestNetworkHandler()
        let instanceID = UUID()
        sessionManager.beginMount(instanceID: instanceID)

        let api = WidgetHostAPI(
            sessionManager: sessionManager,
            storage: storage,
            network: network,
            resolveWidgetID: { id in
                id == instanceID ? "demo.widget" : nil
            }
        )

        do {
            _ = try await api.handle(
                RuntimeTransportRequest(
                    id: "1",
                    method: "rpc",
                    params: .object([
                        "instanceId": .string(instanceID.uuidString),
                        "sessionId": .string("session-1"),
                        "method": .string("unknown.method"),
                        "params": .object([:])
                    ])
                )
            )
            XCTFail("Expected unknown method to fail")
        } catch let error as RuntimeTransportRPCError {
            XCTAssertEqual(error.code, -32601)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHandleRejectsSessionMismatchBeforeDispatch() async {
        let sessionManager = WidgetSessionManager()
        let storage = TestStorageHandler(result: .null)
        let network = TestNetworkHandler()
        let instanceID = UUID()
        sessionManager.beginMount(instanceID: instanceID)
        _ = sessionManager.acceptsWorkerSession(instanceID: instanceID, sessionId: "session-1")

        let api = WidgetHostAPI(
            sessionManager: sessionManager,
            storage: storage,
            network: network,
            resolveWidgetID: { id in
                id == instanceID ? "demo.widget" : nil
            }
        )

        do {
            _ = try await api.handle(
                RuntimeTransportRequest(
                    id: "1",
                    method: "rpc",
                    params: .object([
                        "instanceId": .string(instanceID.uuidString),
                        "sessionId": .string("session-2"),
                        "method": .string("localStorage.allItems"),
                        "params": .object([:])
                    ])
                )
            )
            XCTFail("Expected session mismatch to fail")
        } catch let error as RuntimeTransportRPCError {
            XCTAssertEqual(error.code, -32004)
            XCTAssertNil(storage.lastMethod)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class TestNetworkDataTask: WidgetHostNetworkDataTask {
    var didResume = false
    var didCancel = false
    var completion: ((Data?, URLResponse?, Error?) -> Void)?

    func resume() {
        didResume = true
    }

    func cancel() {
        didCancel = true
        completion?(nil, nil, URLError(.cancelled))
    }

    func complete(data: Data?, response: URLResponse?, error: Error?) {
        completion?(data, response, error)
    }
}

private final class TestStorageHandler: WidgetHostLocalStorageHandling {
    var result: RuntimeJSONValue
    var lastWidgetID: String?
    var lastInstanceID: String?
    var lastMethod: String?

    init(result: RuntimeJSONValue) {
        self.result = result
    }

    func handleRPC(widgetID: String, instanceID: String, method: String, params: RuntimeJSONValue?) throws -> RuntimeJSONValue {
        lastWidgetID = widgetID
        lastInstanceID = instanceID
        lastMethod = method
        return result
    }
}

@MainActor
private final class TestNetworkHandler: WidgetHostNetworkHandling {
    func fetch(_ params: RuntimeFetchRequestParams) async throws -> RuntimeFetchResponsePayload {
        XCTFail("Network handler should not be called in this test")
        return RuntimeFetchResponsePayload(status: 200, statusText: "ok", headers: [:], body: nil, bodyEncoding: "text")
    }

    func cancel(_ params: RuntimeCancelRequestParams) {
        XCTFail("Network handler should not be called in this test")
    }

    func open(_ params: RuntimeBrowserOpenParams) throws {
        XCTFail("Network handler should not be called in this test")
    }
}
