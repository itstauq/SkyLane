import Foundation

enum WidgetAssetResolver {
    static func assetRootURL(forPackageDirectoryURL packageDirectoryURL: URL) -> URL {
        packageDirectoryURL
            .appendingPathComponent(".notch", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
    }

    static func assetURL(for source: String?, under assetRootURL: URL) -> URL? {
        guard let source else { return nil }

        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              URL(string: trimmed)?.scheme == nil else {
            return nil
        }

        let resolved = assetRootURL
            .appendingPathComponent(trimmed)
            .standardizedFileURL
        let assetRootPath = assetRootURL.standardizedFileURL.path

        guard resolved.path == assetRootPath || resolved.path.hasPrefix(assetRootPath + "/") else {
            return nil
        }

        return resolved
    }
}
