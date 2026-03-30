import Foundation
import SwiftUI

struct RenderNodeV2: Codable, Equatable {
    var id: String?
    var type: String
    var key: String?
    var props: [String: RuntimeJSONValue]
    var children: [RenderNodeV2]

    init(
        id: String? = nil,
        type: String,
        key: String?,
        props: [String: RuntimeJSONValue],
        children: [RenderNodeV2]
    ) {
        self.id = id
        self.type = type
        self.key = key
        self.props = props
        self.children = children
    }

    func string(_ key: String) -> String? {
        guard case .string(let value)? = props[key] else { return nil }
        return value
    }

    func number(_ key: String) -> Double? {
        guard case .number(let value)? = props[key] else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? {
        guard case .bool(let value)? = props[key] else { return nil }
        return value
    }

    func value(_ key: String) -> RuntimeJSONValue? {
        props[key]
    }

    func decoded<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        guard let value = props[key] else { return nil }
        return try? value.decode(as: type)
    }
}

struct RuntimeV2Padding: Equatable {
    var top: Double
    var leading: Double
    var bottom: Double
    var trailing: Double

    var edgeInsets: EdgeInsets {
        EdgeInsets(top: top, leading: leading, bottom: bottom, trailing: trailing)
    }
}

enum RuntimeV2FrameDimension: Decodable, Equatable {
    case points(Double)
    case infinity

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .points(number)
            return
        }

        let string = try container.decode(String.self)
        guard string == "infinity" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported frame dimension.")
        }
        self = .infinity
    }

    var cgFloatValue: CGFloat {
        switch self {
        case .points(let value):
            return CGFloat(value)
        case .infinity:
            return .infinity
        }
    }
}

struct RuntimeV2FramePayload: Decodable, Equatable {
    var width: Double?
    var height: Double?
    var maxWidth: RuntimeV2FrameDimension?
    var maxHeight: RuntimeV2FrameDimension?
    var alignment: String?
}

struct RuntimeV2ClipShapePayload: Decodable, Equatable {
    var type: String
    var cornerRadius: Double?
}

struct RuntimeV2OverlayPayload: Decodable, Equatable {
    var node: RenderNodeV2
    var alignment: String?
}

enum RuntimeV2StyleResolver {
    static func color(hex: String?) -> Color? {
        guard let hex else { return nil }
        return Color(hex: hex)
    }

    static func padding(from value: RuntimeJSONValue?) -> RuntimeV2Padding? {
        guard let value else { return nil }

        switch value {
        case .number(let amount):
            return RuntimeV2Padding(top: amount, leading: amount, bottom: amount, trailing: amount)
        case .object(let object):
            let horizontal = object.number("horizontal") ?? 0
            let vertical = object.number("vertical") ?? 0
            return RuntimeV2Padding(
                top: object.number("top") ?? vertical,
                leading: object.number("leading") ?? horizontal,
                bottom: object.number("bottom") ?? vertical,
                trailing: object.number("trailing") ?? horizontal
            )
        default:
            return nil
        }
    }

    static func frame(from value: RuntimeJSONValue?) -> RuntimeV2FramePayload? {
        guard let value else { return nil }
        return try? value.decode(as: RuntimeV2FramePayload.self)
    }

    static func clipShape(from value: RuntimeJSONValue?) -> RuntimeV2ClipShapePayload? {
        guard let value else { return nil }
        return try? value.decode(as: RuntimeV2ClipShapePayload.self)
    }

    static func imageContentMode(_ value: String?) -> ContentMode {
        switch value {
        case "fit":
            return .fit
        default:
            return .fill
        }
    }

    static func fontWeight(_ value: String?, default defaultWeight: Font.Weight) -> Font.Weight {
        switch value {
        case "ultraLight":
            return .ultraLight
        case "thin":
            return .thin
        case "light":
            return .light
        case "regular":
            return .regular
        case "medium":
            return .medium
        case "semibold":
            return .semibold
        case "bold":
            return .bold
        case "heavy":
            return .heavy
        case "black":
            return .black
        default:
            return defaultWeight
        }
    }

    static func fontDesign(_ value: String?) -> Font.Design {
        switch value {
        case "rounded":
            return .rounded
        case "monospaced":
            return .monospaced
        default:
            return .default
        }
    }

    static func horizontalAlignment(_ value: String?) -> HorizontalAlignment {
        switch value {
        case "center":
            return .center
        case "trailing":
            return .trailing
        default:
            return .leading
        }
    }

    static func verticalAlignment(_ value: String?) -> VerticalAlignment {
        switch value {
        case "top":
            return .top
        case "bottom":
            return .bottom
        default:
            return .center
        }
    }

    static func textAlignment(_ value: String?) -> TextAlignment {
        switch value {
        case "center":
            return .center
        case "trailing":
            return .trailing
        default:
            return .leading
        }
    }

    static func textFrameAlignment(_ value: String?) -> Alignment {
        switch value {
        case "center":
            return .center
        case "trailing":
            return .trailing
        default:
            return .leading
        }
    }

    static func alignment(_ value: String?) -> Alignment {
        switch value {
        case "top":
            return .top
        case "bottom":
            return .bottom
        case "leading":
            return .leading
        case "trailing":
            return .trailing
        case "topLeading":
            return .topLeading
        case "topTrailing":
            return .topTrailing
        case "bottomLeading":
            return .bottomLeading
        case "bottomTrailing":
            return .bottomTrailing
        default:
            return .center
        }
    }
}

private extension Dictionary where Key == String, Value == RuntimeJSONValue {
    func number(_ key: String) -> Double? {
        guard case .number(let value)? = self[key] else { return nil }
        return value
    }
}

extension Color {
    init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard normalized.count == 6 || normalized.count == 8,
              let value = UInt64(normalized, radix: 16) else {
            return nil
        }

        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double

        if normalized.count == 8 {
            red = Double((value & 0xFF00_0000) >> 24) / 255
            green = Double((value & 0x00FF_0000) >> 16) / 255
            blue = Double((value & 0x0000_FF00) >> 8) / 255
            alpha = Double(value & 0x0000_00FF) / 255
        } else {
            red = Double((value & 0xFF00_00) >> 16) / 255
            green = Double((value & 0x00FF_00) >> 8) / 255
            blue = Double(value & 0x0000_FF) / 255
            alpha = 1
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
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

    func acceptsWorkerSession(instanceID: UUID, sessionId: String) -> Bool {
        if let session = sessions[instanceID] {
            return session.sessionId == sessionId
        }

        guard var pendingMount = pendingMounts[instanceID] else {
            return false
        }

        if let observedSessionId = pendingMount.observedSessionId {
            return observedSessionId == sessionId
        }

        pendingMount.observedSessionId = sessionId
        pendingMounts[instanceID] = pendingMount
        return true
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
