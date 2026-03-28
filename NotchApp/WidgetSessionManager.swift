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

struct JSONPatchOperation: Decodable, Equatable {
    var op: String
    var path: String
    var value: RuntimeJSONValue?
}

enum MirrorTreePatchError: Error, Equatable, LocalizedError {
    case invalidPatchPayload
    case unsupportedOperation(String)
    case missingValue(String)
    case invalidPointer(String)
    case invalidTarget(String)

    var errorDescription: String? {
        switch self {
        case .invalidPatchPayload:
            return "Patch payload was not a valid JSON Patch array."
        case .unsupportedOperation(let op):
            return "Unsupported JSON Patch op '\(op)'."
        case .missingValue(let path):
            return "Patch op at '\(path)' was missing a value."
        case .invalidPointer(let path):
            return "Patch path '\(path)' was not a valid RFC 6901 pointer."
        case .invalidTarget(let path):
            return "Patch path '\(path)' did not match the current mirror tree."
        }
    }
}

enum RenderTreeSyncAction {
    case applied(RenderNodeV2)
    case requestFullTree(String)
    case ignored
}

enum MirrorTreePatchApplier {
    static func apply(_ operations: [JSONPatchOperation], to root: RuntimeJSONValue) throws -> RuntimeJSONValue {
        var next = root
        for operation in operations {
            next = try apply(operation, to: next)
        }
        return next
    }

    private static func apply(_ operation: JSONPatchOperation, to root: RuntimeJSONValue) throws -> RuntimeJSONValue {
        let tokens = try parse(pointer: operation.path)

        switch operation.op {
        case "add":
            guard let value = operation.value else {
                throw MirrorTreePatchError.missingValue(operation.path)
            }
            return try add(value, at: tokens, in: root, fullPath: operation.path)
        case "remove":
            return try remove(at: tokens, in: root, fullPath: operation.path)
        case "replace":
            guard let value = operation.value else {
                throw MirrorTreePatchError.missingValue(operation.path)
            }
            return try replace(with: value, at: tokens, in: root, fullPath: operation.path)
        default:
            throw MirrorTreePatchError.unsupportedOperation(operation.op)
        }
    }

    private static func parse(pointer: String) throws -> [String] {
        if pointer.isEmpty {
            return []
        }

        guard pointer.first == "/" else {
            throw MirrorTreePatchError.invalidPointer(pointer)
        }

        return try pointer
            .dropFirst()
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { try decode(pointerToken: String($0), fullPath: pointer) }
    }

    private static func decode(pointerToken: String, fullPath: String) throws -> String {
        var result = ""
        var index = pointerToken.startIndex

        while index < pointerToken.endIndex {
            if pointerToken[index] != "~" {
                result.append(pointerToken[index])
                index = pointerToken.index(after: index)
                continue
            }

            let nextIndex = pointerToken.index(after: index)
            guard nextIndex < pointerToken.endIndex else {
                throw MirrorTreePatchError.invalidPointer(fullPath)
            }

            switch pointerToken[nextIndex] {
            case "0":
                result.append("~")
            case "1":
                result.append("/")
            default:
                throw MirrorTreePatchError.invalidPointer(fullPath)
            }

            index = pointerToken.index(after: nextIndex)
        }

        return result
    }

    private static func add(
        _ value: RuntimeJSONValue,
        at tokens: [String],
        in root: RuntimeJSONValue,
        fullPath: String
    ) throws -> RuntimeJSONValue {
        guard let head = tokens.first else {
            return value
        }

        let tail = Array(tokens.dropFirst())

        switch root {
        case .object(var object):
            if tail.isEmpty {
                object[head] = value
                return .object(object)
            }

            guard let child = object[head] else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }

            object[head] = try add(value, at: tail, in: child, fullPath: fullPath)
            return .object(object)
        case .array(var array):
            let index = try arrayIndex(token: head, count: array.count, allowAppend: true, fullPath: fullPath)
            if tail.isEmpty {
                array.insert(value, at: index)
                return .array(array)
            }

            guard array.indices.contains(index) else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }

            array[index] = try add(value, at: tail, in: array[index], fullPath: fullPath)
            return .array(array)
        default:
            throw MirrorTreePatchError.invalidTarget(fullPath)
        }
    }

    private static func remove(
        at tokens: [String],
        in root: RuntimeJSONValue,
        fullPath: String
    ) throws -> RuntimeJSONValue {
        guard let head = tokens.first else {
            throw MirrorTreePatchError.invalidTarget(fullPath)
        }

        let tail = Array(tokens.dropFirst())

        switch root {
        case .object(var object):
            if tail.isEmpty {
                guard object.removeValue(forKey: head) != nil else {
                    throw MirrorTreePatchError.invalidTarget(fullPath)
                }
                return .object(object)
            }

            guard let child = object[head] else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }

            object[head] = try remove(at: tail, in: child, fullPath: fullPath)
            return .object(object)
        case .array(var array):
            let index = try arrayIndex(token: head, count: array.count, allowAppend: false, fullPath: fullPath)
            if tail.isEmpty {
                array.remove(at: index)
                return .array(array)
            }

            array[index] = try remove(at: tail, in: array[index], fullPath: fullPath)
            return .array(array)
        default:
            throw MirrorTreePatchError.invalidTarget(fullPath)
        }
    }

    private static func replace(
        with value: RuntimeJSONValue,
        at tokens: [String],
        in root: RuntimeJSONValue,
        fullPath: String
    ) throws -> RuntimeJSONValue {
        guard let head = tokens.first else {
            return value
        }

        let tail = Array(tokens.dropFirst())

        switch root {
        case .object(var object):
            if tail.isEmpty {
                guard object[head] != nil else {
                    throw MirrorTreePatchError.invalidTarget(fullPath)
                }
                object[head] = value
                return .object(object)
            }

            guard let child = object[head] else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }

            object[head] = try replace(with: value, at: tail, in: child, fullPath: fullPath)
            return .object(object)
        case .array(var array):
            let index = try arrayIndex(token: head, count: array.count, allowAppend: false, fullPath: fullPath)
            if tail.isEmpty {
                array[index] = value
                return .array(array)
            }

            array[index] = try replace(with: value, at: tail, in: array[index], fullPath: fullPath)
            return .array(array)
        default:
            throw MirrorTreePatchError.invalidTarget(fullPath)
        }
    }

    private static func arrayIndex(
        token: String,
        count: Int,
        allowAppend: Bool,
        fullPath: String
    ) throws -> Int {
        if allowAppend && token == "-" {
            return count
        }

        guard let index = Int(token), index >= 0 else {
            throw MirrorTreePatchError.invalidTarget(fullPath)
        }

        if allowAppend {
            guard index <= count else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }
        } else {
            guard index < count else {
                throw MirrorTreePatchError.invalidTarget(fullPath)
            }
        }

        return index
    }
}

struct WidgetRenderNotificationParams: Decodable {
    var instanceId: String
    var sessionId: String
    var kind: String
    var renderRevision: Int
    var data: RuntimeJSONValue
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
        var mirrorTree: RuntimeJSONValue?
    }

    struct WidgetSession {
        var sessionId: String
        var renderRevision: Int
        var mirrorTree: RuntimeJSONValue?
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

    func acceptRender(
        instanceID: UUID,
        sessionId: String,
        kind: String,
        renderRevision: Int,
        data: RuntimeJSONValue
    ) -> RenderTreeSyncAction {
        switch kind {
        case "full":
            return acceptFullRender(
                instanceID: instanceID,
                sessionId: sessionId,
                renderRevision: renderRevision,
                data: data
            )
        case "patch":
            return acceptPatchRender(
                instanceID: instanceID,
                sessionId: sessionId,
                renderRevision: renderRevision,
                patch: data
            )
        default:
            return .ignored
        }
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
            renderRevision: pendingMount?.renderRevision ?? 0,
            mirrorTree: pendingMount?.mirrorTree
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

    private func acceptFullRender(
        instanceID: UUID,
        sessionId: String,
        renderRevision: Int,
        data: RuntimeJSONValue
    ) -> RenderTreeSyncAction {
        let tree: RenderNodeV2
        do {
            tree = try data.decode(as: RenderNodeV2.self)
        } catch {
            return .requestFullTree("Full tree decode failed for \(instanceID.uuidString): \(error.localizedDescription)")
        }

        if var session = sessions[instanceID] {
            guard session.sessionId == sessionId else { return .ignored }
            guard renderRevision >= session.renderRevision else { return .ignored }

            session.renderRevision = renderRevision
            session.mirrorTree = data
            sessions[instanceID] = session
            return .applied(tree)
        }

        guard var pendingMount = pendingMounts[instanceID] else {
            return .ignored
        }

        if let observedSessionId = pendingMount.observedSessionId,
           observedSessionId != sessionId {
            return .ignored
        }

        pendingMount.observedSessionId = sessionId
        pendingMount.renderRevision = renderRevision
        pendingMount.mirrorTree = data
        pendingMounts[instanceID] = pendingMount
        return .applied(tree)
    }

    private func acceptPatchRender(
        instanceID: UUID,
        sessionId: String,
        renderRevision: Int,
        patch: RuntimeJSONValue
    ) -> RenderTreeSyncAction {
        if var session = sessions[instanceID] {
            guard session.sessionId == sessionId else { return .ignored }

            let result = applyPatch(
                instanceDescription: instanceID.uuidString,
                currentRevision: session.renderRevision,
                currentMirrorTree: session.mirrorTree,
                nextRevision: renderRevision,
                patch: patch
            )

            switch result {
            case .applied(let tree, let mirrorTree):
                session.renderRevision = renderRevision
                session.mirrorTree = mirrorTree
                sessions[instanceID] = session
                return .applied(tree)
            case .requestFullTree(let reason):
                return .requestFullTree(reason)
            }
        }

        guard var pendingMount = pendingMounts[instanceID] else {
            return .ignored
        }

        if let observedSessionId = pendingMount.observedSessionId,
           observedSessionId != sessionId {
            return .ignored
        }

        pendingMount.observedSessionId = sessionId
        let result = applyPatch(
            instanceDescription: instanceID.uuidString,
            currentRevision: pendingMount.renderRevision ?? 0,
            currentMirrorTree: pendingMount.mirrorTree,
            nextRevision: renderRevision,
            patch: patch
        )

        switch result {
        case .applied(let tree, let mirrorTree):
            pendingMount.renderRevision = renderRevision
            pendingMount.mirrorTree = mirrorTree
            pendingMounts[instanceID] = pendingMount
            return .applied(tree)
        case .requestFullTree(let reason):
            return .requestFullTree(reason)
        }
    }

    private enum PatchApplyResult {
        case applied(RenderNodeV2, RuntimeJSONValue)
        case requestFullTree(String)
    }

    private func applyPatch(
        instanceDescription: String,
        currentRevision: Int,
        currentMirrorTree: RuntimeJSONValue?,
        nextRevision: Int,
        patch: RuntimeJSONValue
    ) -> PatchApplyResult {
        guard let currentMirrorTree else {
            return .requestFullTree("Patch arrived before a full tree for \(instanceDescription).")
        }

        let expectedRevision = currentRevision + 1
        guard nextRevision == expectedRevision else {
            return .requestFullTree(
                "Expected render revision \(expectedRevision) for \(instanceDescription), got \(nextRevision)."
            )
        }

        let operations: [JSONPatchOperation]
        do {
            operations = try patch.decode(as: [JSONPatchOperation].self)
        } catch {
            return .requestFullTree("Patch payload decode failed for \(instanceDescription): \(error.localizedDescription)")
        }

        do {
            let mirrorTree = try MirrorTreePatchApplier.apply(operations, to: currentMirrorTree)
            let tree = try mirrorTree.decode(as: RenderNodeV2.self)
            return .applied(tree, mirrorTree)
        } catch {
            return .requestFullTree("Patch apply failed for \(instanceDescription): \(error.localizedDescription)")
        }
    }
}
