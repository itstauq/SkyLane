import XCTest
import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

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
    func testAcceptsPendingWorkerSessionBeforeFirstRender() throws {
        let manager = WidgetSessionManager()
        let instanceID = UUID()
        let sessionID = "instance:1"

        manager.beginMount(instanceID: instanceID)

        XCTAssertTrue(manager.acceptsWorkerSession(instanceID: instanceID, sessionId: sessionID))
        XCTAssertEqual(manager.knownSessionID(for: instanceID), sessionID)

        try manager.activate(instanceID: instanceID, sessionId: sessionID)
        XCTAssertEqual(manager.knownSessionID(for: instanceID), sessionID)
    }

    @MainActor
    func testRejectsDifferentPendingWorkerSessionAfterObservation() {
        let manager = WidgetSessionManager()
        let instanceID = UUID()

        manager.beginMount(instanceID: instanceID)

        XCTAssertTrue(manager.acceptsWorkerSession(instanceID: instanceID, sessionId: "instance:1"))
        XCTAssertFalse(manager.acceptsWorkerSession(instanceID: instanceID, sessionId: "instance:2"))
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

    func testRenderNodeV2HelpersDecodeBoolAndTypedPayloads() {
        let node = RenderNodeV2(
            type: "RoundedRect",
            key: nil,
            props: [
                "checked": .bool(true),
                "frame": .object([
                    "width": .number(120),
                    "maxWidth": .string("infinity"),
                    "alignment": .string("center")
                ]),
                "clipShape": .object([
                    "type": .string("roundedRect"),
                    "cornerRadius": .number(14)
                ])
            ],
            children: []
        )

        XCTAssertEqual(node.bool("checked"), true)
        XCTAssertEqual(node.decoded("frame", as: RuntimeV2FramePayload.self)?.width, 120)
        XCTAssertEqual(node.decoded("frame", as: RuntimeV2FramePayload.self)?.maxWidth, .infinity)
        XCTAssertEqual(node.decoded("clipShape", as: RuntimeV2ClipShapePayload.self)?.cornerRadius, 14)
    }

    func testRuntimeV2PaddingParserSupportsScalarAxisAndEdgeValues() {
        let scalar = RuntimeV2StyleResolver.padding(from: .number(8))
        XCTAssertEqual(scalar, RuntimeV2Padding(top: 8, leading: 8, bottom: 8, trailing: 8))

        let object = RuntimeV2StyleResolver.padding(from: .object([
            "horizontal": .number(10),
            "vertical": .number(6),
            "bottom": .number(12)
        ]))
        XCTAssertEqual(object, RuntimeV2Padding(top: 6, leading: 10, bottom: 12, trailing: 10))
    }

    func testRuntimeV2FrameParserSupportsInfinity() {
        let frame = RuntimeV2StyleResolver.frame(from: .object([
            "width": .number(88),
            "maxWidth": .string("infinity"),
            "maxHeight": .number(120),
            "alignment": .string("trailing")
        ]))

        XCTAssertEqual(frame?.width, 88)
        XCTAssertEqual(frame?.maxWidth, .infinity)
        XCTAssertEqual(frame?.maxHeight, .points(120))
        XCTAssertEqual(frame?.alignment, "trailing")
    }

    func testRuntimeV2ImageContentModeDefaultsToFillAndSupportsFit() {
        XCTAssertEqual(RuntimeV2StyleResolver.imageContentMode(nil), .fill)
        XCTAssertEqual(RuntimeV2StyleResolver.imageContentMode("fill"), .fill)
        XCTAssertEqual(RuntimeV2StyleResolver.imageContentMode("fit"), .fit)
        XCTAssertEqual(RuntimeV2StyleResolver.imageContentMode("unexpected"), .fill)
    }

    func testRuntimeV2AlignmentAndClipShapeHelpers() {
        XCTAssertEqual(RuntimeV2StyleResolver.horizontalAlignment("trailing"), .trailing)
        XCTAssertEqual(RuntimeV2StyleResolver.verticalAlignment("top"), .top)
        XCTAssertEqual(RuntimeV2StyleResolver.textAlignment("center"), .center)
        XCTAssertEqual(RuntimeV2StyleResolver.alignment("bottomTrailing"), .bottomTrailing)

        let clipShape = RuntimeV2StyleResolver.clipShape(from: .object([
            "type": .string("roundedRect"),
            "cornerRadius": .number(18)
        ]))
        XCTAssertEqual(clipShape, RuntimeV2ClipShapePayload(type: "roundedRect", cornerRadius: 18))
    }

    func testColorHexParserAcceptsRgbAndRgba() {
        XCTAssertNotNil(Color(hex: "#112233"))
        XCTAssertNotNil(Color(hex: "#112233CC"))
        XCTAssertNil(Color(hex: "#XYZXYZ"))
    }

    func testWidgetAssetResolverResolvesLocalAssetsInsideBuildDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".notch/build/assets", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let assetRootURL = WidgetAssetResolver.assetRootURL(forPackageDirectoryURL: root)

        XCTAssertEqual(
            assetRootURL.path,
            root.appendingPathComponent(".notch/build", isDirectory: true).path
        )
        XCTAssertEqual(
            WidgetAssetResolver.assetURL(for: "assets/icon.png", under: assetRootURL)?.path,
            root.appendingPathComponent(".notch/build/assets/icon.png").path
        )
        XCTAssertEqual(
            WidgetAssetResolver.assetURL(for: "./assets/icon.png", under: assetRootURL)?.path,
            root.appendingPathComponent(".notch/build/assets/icon.png").path
        )
    }

    func testWidgetAssetResolverRejectsEscapingAndAbsoluteAssetPaths() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let assetRootURL = WidgetAssetResolver.assetRootURL(forPackageDirectoryURL: root)

        XCTAssertNil(WidgetAssetResolver.assetURL(for: "../secret.png", under: assetRootURL))
        XCTAssertNil(WidgetAssetResolver.assetURL(for: "/tmp/secret.png", under: assetRootURL))
        XCTAssertNil(WidgetAssetResolver.assetURL(for: "file:///tmp/secret.png", under: assetRootURL))
    }

    func testWidgetImagePipelineCachesLoadedImages() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("cover.png")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTestPNG(size: CGSize(width: 640, height: 320), to: imageURL)
        defer {
            WidgetImagePipeline.clearCache()
            try? FileManager.default.removeItem(at: root)
        }

        WidgetImagePipeline.clearCache()

        let loaded = await WidgetImagePipeline.image(
            at: imageURL,
            targetSize: CGSize(width: 96, height: 48),
            scale: 1,
            contentMode: "fill"
        )
        XCTAssertNotNil(loaded)

        let cached = WidgetImagePipeline.cachedImage(
            at: imageURL,
            targetSize: CGSize(width: 96, height: 48),
            scale: 1,
            contentMode: "fill"
        )
        XCTAssertNotNil(cached)
    }

    func testWidgetImagePipelineReadsIntrinsicSizeFromLocalAssetMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("cover.png")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTestPNG(size: CGSize(width: 640, height: 320), to: imageURL)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            WidgetImagePipeline.intrinsicSize(at: imageURL),
            CGSize(width: 640, height: 320)
        )
    }

    func testWidgetImagePipelineReadsOrientationCorrectedIntrinsicSize() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("portrait.jpg")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTestJPEG(
            size: CGSize(width: 640, height: 320),
            orientation: .right,
            to: imageURL
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            WidgetImagePipeline.intrinsicSize(at: imageURL),
            CGSize(width: 320, height: 640)
        )
    }

    func testWidgetImagePipelineUsesRawPixelOrientationForThumbnailRequests() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("portrait.jpg")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTestJPEG(
            size: CGSize(width: 640, height: 320),
            orientation: .right,
            to: imageURL
        )
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        XCTAssertEqual(
            WidgetImagePipeline.thumbnailRequestSize(
                for: CGSize(width: 320, height: 640),
                at: imageURL
            ),
            CGSize(width: 640, height: 320)
        )
    }

    func testRuntimeV2ImageLayoutResolverUsesMeasuredSizeForRequestsWhenParentConstrainsImage() {
        let explicitFrameSize: CGSize? = nil
        let measuredSize = CGSize(width: 180, height: 96)
        let intrinsicSize = CGSize(width: 2000, height: 1000)

        XCTAssertEqual(
            RuntimeV2ImageLayoutResolver.layoutSize(
                explicitFrameSize: explicitFrameSize,
                measuredSize: measuredSize,
                intrinsicSize: intrinsicSize
            ),
            intrinsicSize
        )

        XCTAssertEqual(
            RuntimeV2ImageLayoutResolver.requestSize(
                explicitFrameSize: explicitFrameSize,
                measuredSize: measuredSize,
                intrinsicSize: intrinsicSize
            ),
            measuredSize
        )
    }

    func testWidgetImagePipelineDownsamplesLargeImagesToTargetSize() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("large.png")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeTestPNG(size: CGSize(width: 1600, height: 1200), to: imageURL)
        defer {
            WidgetImagePipeline.clearCache()
            try? FileManager.default.removeItem(at: root)
        }

        WidgetImagePipeline.clearCache()

        let loadedImage = await WidgetImagePipeline.image(
            at: imageURL,
            targetSize: CGSize(width: 120, height: 80),
            scale: 1,
            contentMode: "fit"
        )
        let image = try XCTUnwrap(loadedImage)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))

        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 120)
    }

    func testWidgetImagePipelineReturnsNilForCorruptFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let imageURL = root.appendingPathComponent("corrupt.png")

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: imageURL)
        defer {
            WidgetImagePipeline.clearCache()
            try? FileManager.default.removeItem(at: root)
        }

        WidgetImagePipeline.clearCache()

        let image = await WidgetImagePipeline.image(
            at: imageURL,
            targetSize: CGSize(width: 64, height: 64),
            scale: 1,
            contentMode: "fill"
        )

        XCTAssertNil(image)
    }

    func testWidgetImagePipelineReturnsNilForMissingFiles() async {
        let imageURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)

        WidgetImagePipeline.clearCache()

        let image = await WidgetImagePipeline.image(
            at: imageURL,
            targetSize: CGSize(width: 64, height: 64),
            scale: 1,
            contentMode: "fill"
        )

        XCTAssertNil(image)
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

private func writeTestPNG(size: CGSize, to url: URL) throws {
    let width = Int(size.width)
    let height = Int(size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let rep else {
        XCTFail("Failed to create bitmap image rep")
        return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemBlue.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSGraphicsContext.restoreGraphicsState()

    let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    try data.write(to: url)
}

private func writeTestJPEG(
    size: CGSize,
    orientation: CGImagePropertyOrientation,
    to url: URL
) throws {
    let width = Int(size.width)
    let height = Int(size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )

    guard let rep else {
        XCTFail("Failed to create bitmap image rep")
        return
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemPink.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = rep.cgImage else {
        XCTFail("Failed to create CGImage")
        return
    }

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        XCTFail("Failed to create image destination")
        return
    }

    CGImageDestinationAddImage(
        destination,
        cgImage,
        [
            kCGImagePropertyOrientation: orientation.rawValue
        ] as CFDictionary
    )

    XCTAssertTrue(CGImageDestinationFinalize(destination))
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
