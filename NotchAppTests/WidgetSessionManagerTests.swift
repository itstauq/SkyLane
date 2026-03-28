import XCTest

final class WidgetSessionManagerTests: XCTestCase {
    func testApplyPatchInsertsArrayChild() throws {
        let root = stackNode(children: [
            textNode("Before")
        ])

        let patched = try MirrorTreePatchApplier.apply([
            JSONPatchOperation(op: "add", path: "/children/1", value: textNode("After"))
        ], to: root)

        XCTAssertEqual(
            patched,
            stackNode(children: [
                textNode("Before"),
                textNode("After")
            ])
        )
    }

    func testApplyPatchReplacesNestedProp() throws {
        let root = buttonNode(title: "Count 0")

        let patched = try MirrorTreePatchApplier.apply([
            JSONPatchOperation(op: "replace", path: "/props/title", value: .string("Count 1"))
        ], to: root)

        XCTAssertEqual(patched, buttonNode(title: "Count 1"))
    }

    func testApplyPatchSupportsRFC6901Escaping() throws {
        let root: RuntimeJSONValue = .object([
            "type": .string("Text"),
            "key": .null,
            "props": .object([
                "a/b": .string("slash"),
                "m~n": .string("tilde")
            ]),
            "children": .array([])
        ])

        let patched = try MirrorTreePatchApplier.apply([
            JSONPatchOperation(op: "replace", path: "/props/a~1b", value: .string("updated-slash")),
            JSONPatchOperation(op: "replace", path: "/props/m~0n", value: .string("updated-tilde"))
        ], to: root)

        XCTAssertEqual(
            patched,
            .object([
                "type": .string("Text"),
                "key": .null,
                "props": .object([
                    "a/b": .string("updated-slash"),
                    "m~n": .string("updated-tilde")
                ]),
                "children": .array([])
            ])
        )
    }

    func testApplyPatchRejectsUnsupportedOperations() {
        XCTAssertThrowsError(
            try MirrorTreePatchApplier.apply([
                JSONPatchOperation(op: "move", path: "/children/0", value: nil)
            ], to: stackNode(children: []))
        ) { error in
            XCTAssertEqual(error as? MirrorTreePatchError, .unsupportedOperation("move"))
        }
    }

    @MainActor
    func testAcceptRenderRequestsFullTreeOnRevisionGap() throws {
        let manager = WidgetSessionManager()
        let instanceID = UUID()
        let sessionID = "instance:1"

        manager.beginMount(instanceID: instanceID)
        XCTAssertApplied(
            manager.acceptRender(
                instanceID: instanceID,
                sessionId: sessionID,
                kind: "full",
                renderRevision: 1,
                data: stackNode(children: [])
            )
        )
        try manager.activate(instanceID: instanceID, sessionId: sessionID)

        XCTAssertRequestsFullTree(
            manager.acceptRender(
                instanceID: instanceID,
                sessionId: sessionID,
                kind: "patch",
                renderRevision: 3,
                data: .array([])
            )
        )
    }

    @MainActor
    func testAcceptRenderRequestsFullTreeOnUnsupportedPatchOp() throws {
        let manager = WidgetSessionManager()
        let instanceID = UUID()
        let sessionID = "instance:1"

        manager.beginMount(instanceID: instanceID)
        XCTAssertApplied(
            manager.acceptRender(
                instanceID: instanceID,
                sessionId: sessionID,
                kind: "full",
                renderRevision: 1,
                data: stackNode(children: [])
            )
        )
        try manager.activate(instanceID: instanceID, sessionId: sessionID)

        XCTAssertRequestsFullTree(
            manager.acceptRender(
                instanceID: instanceID,
                sessionId: sessionID,
                kind: "patch",
                renderRevision: 2,
                data: .array([
                    .object([
                        "op": .string("move"),
                        "path": .string("/children/0")
                    ])
                ])
            )
        )
    }
}

private func stackNode(children: [RuntimeJSONValue]) -> RuntimeJSONValue {
    .object([
        "type": .string("Stack"),
        "key": .null,
        "props": .object([
            "spacing": .number(0)
        ]),
        "children": .array(children)
    ])
}

private func textNode(_ text: String) -> RuntimeJSONValue {
    .object([
        "type": .string("Text"),
        "key": .null,
        "props": .object([
            "text": .string(text)
        ]),
        "children": .array([])
    ])
}

private func buttonNode(title: String) -> RuntimeJSONValue {
    .object([
        "type": .string("Button"),
        "key": .null,
        "props": .object([
            "title": .string(title),
            "onPress": .string("cb_1")
        ]),
        "children": .array([])
    ])
}

private func XCTAssertApplied(
    _ action: RenderTreeSyncAction,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .applied = action else {
        XCTFail("Expected render to apply, got \(action)", file: file, line: line)
        return
    }
}

private func XCTAssertRequestsFullTree(
    _ action: RenderTreeSyncAction,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .requestFullTree(let reason) = action else {
        XCTFail("Expected render to request a full tree, got \(action)", file: file, line: line)
        return
    }

    XCTAssertFalse(reason.isEmpty, file: file, line: line)
}
