import AppKit
import Foundation
import ImageIO
import Nuke

enum WidgetImagePipelineContentMode {
    case fill
    case fit

    init(_ value: String?) {
        switch value {
        case "fit":
            self = .fit
        default:
            self = .fill
        }
    }

    var thumbnailContentMode: ImageProcessingOptions.ContentMode {
        switch self {
        case .fill:
            return .aspectFill
        case .fit:
            return .aspectFit
        }
    }
}

enum WidgetImagePipeline {
    private struct ImageMetadata {
        let pixelSize: CGSize
        let orientation: CGImagePropertyOrientation

        var displaySize: CGSize {
            if orientation.swapsDimensions {
                return CGSize(width: pixelSize.height, height: pixelSize.width)
            }

            return pixelSize
        }
    }

    private static let imageCache = ImageCache()

    private static let pipeline: ImagePipeline = {
        var configuration = ImagePipeline.Configuration()
        configuration.imageCache = imageCache
        configuration.dataCache = nil
        configuration.isLocalResourcesSupportEnabled = true
        configuration.isTaskCoalescingEnabled = true
        configuration.isProgressiveDecodingEnabled = false
        return ImagePipeline(configuration: configuration)
    }()

    static func image(
        at url: URL,
        targetSize: CGSize,
        scale: CGFloat = 1,
        contentMode: String? = nil
    ) async -> NSImage? {
        guard targetSize.width > 0, targetSize.height > 0 else {
            return nil
        }

        let request = makeRequest(
            url: url,
            targetSize: targetSize,
            scale: scale,
            contentMode: contentMode
        )

        if let cached = cachedImage(for: request) {
            return cached
        }

        do {
            return try await pipeline.image(for: request)
        } catch {
            return nil
        }
    }

    static func cachedImage(
        at url: URL,
        targetSize: CGSize,
        scale: CGFloat = 1,
        contentMode: String? = nil
    ) -> NSImage? {
        guard targetSize.width > 0, targetSize.height > 0 else {
            return nil
        }

        return cachedImage(
            for: makeRequest(
                url: url,
                targetSize: targetSize,
                scale: scale,
                contentMode: contentMode
            )
        )
    }

    static func intrinsicSize(at url: URL) -> CGSize? {
        imageMetadata(at: url)?.displaySize
    }

    static func clearCache() {
        pipeline.cache.removeAll(caches: [.memory])
    }

    static func thumbnailRequestSize(for targetSize: CGSize, at url: URL) -> CGSize {
        guard let metadata = imageMetadata(at: url), metadata.orientation.swapsDimensions else {
            return targetSize
        }

        return CGSize(width: targetSize.height, height: targetSize.width)
    }

    private static func cachedImage(for request: ImageRequest) -> NSImage? {
        pipeline.cache.cachedImage(for: request, caches: [.memory])?.image
    }

    private static func makeRequest(
        url: URL,
        targetSize: CGSize,
        scale: CGFloat,
        contentMode: String?
    ) -> ImageRequest {
        let requestTargetSize = thumbnailRequestSize(for: targetSize, at: url)
        let pixelSize = quantizedPixelSize(for: requestTargetSize, scale: scale)
        let contentMode = WidgetImagePipelineContentMode(contentMode)
        let thumbnail = ImageRequest.ThumbnailOptions(
            size: pixelSize,
            unit: .pixels,
            contentMode: contentMode.thumbnailContentMode
        )

        return ImageRequest(
            url: url,
            userInfo: [
                .thumbnailKey: thumbnail
            ]
        )
    }

    private static func quantizedPixelSize(for targetSize: CGSize, scale: CGFloat) -> CGSize {
        let scale = max(scale, 1)
        let width = max(1, ceil(targetSize.width * scale))
        let height = max(1, ceil(targetSize.height * scale))
        return CGSize(width: width, height: height)
    }

    private static func imageMetadata(at url: URL) -> ImageMetadata? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
              let width = numericProperty(kCGImagePropertyPixelWidth, in: properties),
              let height = numericProperty(kCGImagePropertyPixelHeight, in: properties),
              width > 0,
              height > 0 else {
            return nil
        }

        return ImageMetadata(
            pixelSize: CGSize(width: width, height: height),
            orientation: imageOrientation(from: properties)
        )
    }

    private static func numericProperty(_ key: CFString, in properties: [CFString: Any]) -> CGFloat? {
        if let value = properties[key] as? CGFloat {
            return value
        }

        if let value = properties[key] as? NSNumber {
            return CGFloat(truncating: value)
        }

        return nil
    }

    private static func imageOrientation(from properties: [CFString: Any]) -> CGImagePropertyOrientation {
        if let rawValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            return orientation
        }

        if let rawValue = (properties[kCGImagePropertyTIFFOrientation] as? NSNumber)?.uint32Value,
           let orientation = CGImagePropertyOrientation(rawValue: rawValue) {
            return orientation
        }

        return .up
    }
}

enum RuntimeV2ImageLayoutResolver {
    static func layoutSize(
        explicitFrameSize: CGSize?,
        measuredSize: CGSize,
        intrinsicSize: CGSize?
    ) -> CGSize? {
        let explicitWidth = normalized(explicitFrameSize?.width)
        let explicitHeight = normalized(explicitFrameSize?.height)

        if let explicitWidth, let explicitHeight {
            return CGSize(width: explicitWidth, height: explicitHeight)
        }

        if let intrinsicSize = normalized(intrinsicSize) {
            if let explicitWidth, intrinsicSize.width > 0 {
                return CGSize(
                    width: explicitWidth,
                    height: explicitWidth * intrinsicSize.height / intrinsicSize.width
                )
            }

            if let explicitHeight, intrinsicSize.height > 0 {
                return CGSize(
                    width: explicitHeight * intrinsicSize.width / intrinsicSize.height,
                    height: explicitHeight
                )
            }

            return intrinsicSize
        }

        return normalized(measuredSize)
    }

    static func requestSize(
        explicitFrameSize: CGSize?,
        measuredSize: CGSize,
        intrinsicSize: CGSize?
    ) -> CGSize? {
        let explicitWidth = normalized(explicitFrameSize?.width)
        let explicitHeight = normalized(explicitFrameSize?.height)

        if let explicitWidth, let explicitHeight {
            return CGSize(width: explicitWidth, height: explicitHeight)
        }

        if let measuredSize = normalized(measuredSize) {
            let width = explicitWidth ?? measuredSize.width
            let height = explicitHeight ?? measuredSize.height
            if width > 0, height > 0 {
                return CGSize(width: width, height: height)
            }
        }

        return layoutSize(
            explicitFrameSize: explicitFrameSize,
            measuredSize: measuredSize,
            intrinsicSize: intrinsicSize
        )
    }

    private static func normalized(_ value: CGFloat?) -> CGFloat? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func normalized(_ size: CGSize?) -> CGSize? {
        guard let size else { return nil }
        let width = max(0, size.width)
        let height = max(0, size.height)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}

private extension CGImagePropertyOrientation {
    var swapsDimensions: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            return true
        default:
            return false
        }
    }
}
