import Foundation

struct RenderNodeV2: Codable, Equatable {
    var type: String
    var key: String?
    var props: [String: RuntimeJSONValue]
    var children: [RenderNodeV2]

    func string(_ key: String) -> String? {
        guard case .string(let value)? = props[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value)? = props[key] else { return nil }
        return value
    }
}

struct WidgetRenderNotificationParams: Decodable {
    var instanceId: String
    var sessionId: String
    var kind: String
    var renderRevision: Int
    var data: RenderNodeV2
}

struct WidgetErrorNotificationParams: Decodable {
    struct Payload: Decodable {
        var message: String
        var stack: String?
    }

    var instanceId: String
    var sessionId: String
    var error: Payload
}

@MainActor
final class WidgetSessionManager {
    struct PendingMount {
        var observedSessionId: String?
        var renderRevision: Int?
    }

    struct WidgetSession {
        var sessionId: String
        var renderRevision: Int
    }

    private(set) var pendingMounts: [UUID: PendingMount] = [:]
    private(set) var sessions: [UUID: WidgetSession] = [:]

    func beginMount(instanceID: UUID) {
        if pendingMounts[instanceID] == nil {
            pendingMounts[instanceID] = PendingMount()
        }
    }

    func hasPendingMount(for instanceID: UUID) -> Bool {
        pendingMounts[instanceID] != nil
    }

    func acceptRender(instanceID: UUID, sessionId: String, renderRevision: Int) -> Bool {
        if var session = sessions[instanceID] {
            guard session.sessionId == sessionId else { return false }
            session.renderRevision = renderRevision
            sessions[instanceID] = session
            return true
        }

        guard var pendingMount = pendingMounts[instanceID] else {
            return false
        }

        pendingMount.observedSessionId = sessionId
        pendingMount.renderRevision = renderRevision
        pendingMounts[instanceID] = pendingMount
        return true
    }

    func activate(instanceID: UUID, sessionId: String) throws {
        let pendingMount = pendingMounts.removeValue(forKey: instanceID)
        if let observedSessionId = pendingMount?.observedSessionId,
           observedSessionId != sessionId {
            throw NSError(
                domain: "NotchWidgetRuntime",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Early render session mismatch for \(instanceID.uuidString)."]
            )
        }

        sessions[instanceID] = WidgetSession(
            sessionId: sessionId,
            renderRevision: pendingMount?.renderRevision ?? 0
        )
    }

    func knownSessionID(for instanceID: UUID) -> String? {
        sessions[instanceID]?.sessionId ?? pendingMounts[instanceID]?.observedSessionId
    }

    func remove(instanceID: UUID) {
        pendingMounts.removeValue(forKey: instanceID)
        sessions.removeValue(forKey: instanceID)
    }

    func reset() {
        pendingMounts.removeAll()
        sessions.removeAll()
    }
}
