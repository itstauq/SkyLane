import Foundation
import SwiftUI

struct SavedView: Identifiable, Codable, Equatable {
    static let homeID = UUID(uuidString: "52A637D9-6F60-4CC5-9F86-23F2C50555D1")!
    static let focusID = UUID(uuidString: "A01A0F0C-C616-4339-AF1B-5B35AD3C54C9")!
    static let planID = UUID(uuidString: "EE8FB2C5-4E2A-47C1-BFA9-E03F52AA8849")!

    var id: UUID
    var name: String
    var icon: String

    init(id: UUID = UUID(), name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    static let defaultViews: [SavedView] = [
        SavedView(id: homeID, name: "Home", icon: "house.fill"),
        SavedView(id: focusID, name: "Focus", icon: "timer"),
        SavedView(id: planID, name: "Plan", icon: "calendar"),
    ]
}

struct WidgetPackage: Identifiable, Codable, Equatable {
    var id: String
    var version: String
    var directoryPath: String
    var manifestPath: String

    var directoryURL: URL {
        URL(fileURLWithPath: directoryPath, isDirectory: true)
    }

    var manifestURL: URL {
        URL(fileURLWithPath: manifestPath)
    }
}

struct WidgetDefinition: Identifiable, Codable, Equatable {
    var id: String
    var title: String
    var icon: String
    var description: String?
    var minSpan: Int
    var maxSpan: Int
    var package: WidgetPackage
    var entryFilePath: String?

    var caption: String {
        description ?? "Widget"
    }

    var packageDirectoryURL: URL {
        package.directoryURL
    }

    var entryFileURL: URL? {
        guard let entryFilePath else { return nil }
        return URL(fileURLWithPath: entryFilePath)
    }

    var bundleFileURL: URL {
        packageDirectoryURL
            .appendingPathComponent(".notch", isDirectory: true)
            .appendingPathComponent("build", isDirectory: true)
            .appendingPathComponent("index.cjs")
    }

    var assetRootURL: URL {
        WidgetAssetResolver.assetRootURL(forPackageDirectoryURL: packageDirectoryURL)
    }

    func assetURL(for source: String?) -> URL? {
        WidgetAssetResolver.assetURL(for: source, under: assetRootURL)
    }

    var tint: Color {
        let palette: [Color] = [
            Color(red: 0.46, green: 0.68, blue: 0.98),
            Color(red: 0.99, green: 0.64, blue: 0.38),
            Color(red: 0.72, green: 0.58, blue: 0.98),
            Color(red: 0.37, green: 0.86, blue: 0.72),
            Color(red: 0.96, green: 0.78, blue: 0.35),
            Color(red: 0.98, green: 0.5, blue: 0.63),
            Color(red: 0.52, green: 0.88, blue: 0.96),
        ]
        return palette[abs(id.hashValue) % palette.count]
    }

    static func missing(id: String) -> WidgetDefinition {
        WidgetDefinition(
            id: id,
            title: "Missing Widget",
            icon: "exclamationmark.triangle.fill",
            description: "Unavailable",
            minSpan: 3,
            maxSpan: ViewLayout.columnCount,
            package: WidgetPackage(
                id: id,
                version: "0.0.0",
                directoryPath: RepoPaths.installedWidgetsRoot.path,
                manifestPath: RepoPaths.installedWidgetsRoot.appendingPathComponent("package.json").path
            ),
            entryFilePath: nil
        )
    }
}

struct WidgetManifest: Codable {
    struct NotchManifest: Codable {
        var id: String
        var title: String
        var icon: String
        var minSpan: Int
        var maxSpan: Int
        var description: String?
        var entry: String?
    }

    var name: String
    var version: String
    var notch: NotchManifest
}

enum WidgetCatalog {
    static func discover(log: FileLog = FileLog()) -> [WidgetDefinition] {
        WidgetInstall.syncCanonicalWidgets(log: log)

        let widgetsRoot = RepoPaths.installedWidgetsRoot
        guard let packageURLs = try? FileManager.default.contentsOfDirectory(
            at: widgetsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            log.write("Widget catalog: widgets directory missing at \(widgetsRoot.path)")
            return []
        }

        var definitions: [WidgetDefinition] = []

        for packageURL in packageURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = packageURL.appendingPathComponent("package.json")

            guard let data = try? Data(contentsOf: manifestURL) else {
                log.write("Widget catalog: missing package.json at \(manifestURL.path)")
                continue
            }

            do {
                let manifest = try JSONDecoder().decode(WidgetManifest.self, from: data)
                let notch = manifest.notch

                guard !notch.id.isEmpty, !notch.title.isEmpty else {
                    log.write("Widget catalog: invalid manifest at \(manifestURL.path) (missing id/title)")
                    continue
                }

                guard notch.minSpan > 0, notch.maxSpan >= notch.minSpan, notch.maxSpan <= ViewLayout.columnCount else {
                    log.write("Widget catalog: invalid span range for \(notch.id)")
                    continue
                }

                let sourcePackageURL = packageURL.resolvingSymlinksInPath().standardizedFileURL
                let package = WidgetPackage(
                    id: manifest.name,
                    version: manifest.version,
                    directoryPath: sourcePackageURL.path,
                    manifestPath: manifestURL.path
                )
                let entryRelative = notch.entry ?? "src/index.tsx"
                let entryURL = sourcePackageURL.appendingPathComponent(entryRelative)
                guard FileManager.default.fileExists(atPath: entryURL.path) else {
                    log.write("Widget catalog: missing entry file for \(notch.id) at \(entryURL.path)")
                    continue
                }

                let definition = WidgetDefinition(
                    id: notch.id,
                    title: notch.title,
                    icon: notch.icon,
                    description: notch.description,
                    minSpan: notch.minSpan,
                    maxSpan: notch.maxSpan,
                    package: package,
                    entryFilePath: entryURL.path
                )

                definitions.append(definition)
            } catch {
                log.write("Widget catalog: failed to decode \(manifestURL.path): \(error.localizedDescription)")
            }
        }

        return definitions
    }
}

struct WidgetInstance: Identifiable, Codable, Equatable {
    var id: UUID
    var widgetID: String
    var startColumn: Int
    var span: Int

    init(id: UUID = UUID(), widgetID: String, startColumn: Int, span: Int) {
        self.id = id
        self.widgetID = widgetID
        self.startColumn = startColumn
        self.span = span
    }
}

struct ViewLayout: Codable, Equatable {
    static let columnCount = 12
    var widgets: [WidgetInstance] = []
}

struct ValidatedViewLayout {
    var layout: ViewLayout
    var occupancy: [UUID?]
}

enum RepoPaths {
    static let repoRoot: URL = {
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL,
        ]

        // The repository root is only meaningful when running from a checkout.
        for candidate in candidates {
            var current = candidate.standardizedFileURL
            if !current.hasDirectoryPath {
                current.deleteLastPathComponent()
            }

            while true {
                let projectURL = current.appendingPathComponent("NotchApp.xcodeproj")
                if fm.fileExists(atPath: projectURL.path) {
                    return current
                }

                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                current = parent
            }
        }

        return URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
    }()

    static let developmentWidgetRuntimeRoot = repoRoot.appendingPathComponent("runtime", isDirectory: true)

    static let bundledWidgetRuntimeRoot: URL? = {
        Bundle.main.resourceURL?.appendingPathComponent("WidgetRuntime", isDirectory: true)
    }()

    static let applicationSupportRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? repoRoot
        return base.appendingPathComponent("NotchApp", isDirectory: true)
    }()

    static let installedWidgetsRoot = applicationSupportRoot.appendingPathComponent("Widgets", isDirectory: true)
    static let savedViewsSnapshotURL = applicationSupportRoot.appendingPathComponent("saved-views.json")

}

private struct PersistedViewStateSnapshot: Codable {
    var views: [SavedView]
    var selectedViewID: UUID
    var layoutsByViewID: [UUID: ViewLayout]

    private enum CodingKeys: String, CodingKey {
        case views
        case selectedViewID
        case layoutsByViewID
    }

    init(views: [SavedView], selectedViewID: UUID, layoutsByViewID: [UUID: ViewLayout]) {
        self.views = views
        self.selectedViewID = selectedViewID
        self.layoutsByViewID = layoutsByViewID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        views = try container.decode([SavedView].self, forKey: .views)
        selectedViewID = try container.decode(UUID.self, forKey: .selectedViewID)
        let rawLayouts = try container.decode([String: ViewLayout].self, forKey: .layoutsByViewID)
        layoutsByViewID = Dictionary(
            uniqueKeysWithValues: rawLayouts.compactMap { key, value in
                guard let id = UUID(uuidString: key) else { return nil }
                return (id, value)
            }
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(views, forKey: .views)
        try container.encode(selectedViewID, forKey: .selectedViewID)
        let rawLayouts = Dictionary(
            uniqueKeysWithValues: layoutsByViewID.map { key, value in
                (key.uuidString, value)
            }
        )
        try container.encode(rawLayouts, forKey: .layoutsByViewID)
    }
}

enum WidgetInstall {
    private enum SourceKind {
        case bundled
    }

    static func syncCanonicalWidgets(log: FileLog = FileLog()) {
        let fileManager = FileManager.default
        let installedRoot = RepoPaths.installedWidgetsRoot

        do {
            try fileManager.createDirectory(at: installedRoot, withIntermediateDirectories: true)
        } catch {
            log.write("Widget install: failed to create installed widgets directory: \(error.localizedDescription)")
            return
        }

        if let bundledRuntimeRoot = RepoPaths.bundledWidgetRuntimeRoot,
           fileManager.fileExists(atPath: bundledRuntimeRoot.path) {
            syncWidgets(
                from: bundledRuntimeRoot.appendingPathComponent("widgets", isDirectory: true),
                into: installedRoot,
                sourceKind: .bundled,
                log: log
            )
        }

    }

    private static func syncWidgets(from sourceRoot: URL, into installedRoot: URL, sourceKind: SourceKind, log: FileLog) {
        let fileManager = FileManager.default

        guard let packageURLs = try? fileManager.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var discoveredIDs = Set<String>()

        for packageURL in packageURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = packageURL.appendingPathComponent("package.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(WidgetManifest.self, from: data) else {
                continue
            }

            let widgetID = manifest.notch.id
            guard !widgetID.isEmpty else { continue }
            discoveredIDs.insert(widgetID)

            let linkURL = installedRoot.appendingPathComponent(widgetID, isDirectory: true)
            let resolvedSourcePath = packageURL.standardizedFileURL.path

            if installedEntryExists(at: linkURL) {
                let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
                if let existingTarget,
                   URL(fileURLWithPath: existingTarget).standardizedFileURL.path == resolvedSourcePath {
                    continue
                }

                if !shouldReplaceExistingWidget(at: linkURL, sourceKind: sourceKind) {
                    continue
                }

                do {
                    try fileManager.removeItem(at: linkURL)
                } catch {
                    log.write("Widget install: failed to replace \(widgetID): \(error.localizedDescription)")
                    continue
                }
            }

            do {
                try fileManager.createSymbolicLink(atPath: linkURL.path, withDestinationPath: resolvedSourcePath)
            } catch {
                log.write("Widget install: failed to link \(widgetID): \(error.localizedDescription)")
            }
        }

        cleanupStaleManagedLinks(
            sourceKind: sourceKind,
            installedRoot: installedRoot,
            discoveredIDs: discoveredIDs,
            log: log
        )
    }

    private static func shouldReplaceExistingWidget(at linkURL: URL, sourceKind: SourceKind) -> Bool {
        guard let existingTarget = try? FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) else {
            return false
        }

        let existingTargetPath = URL(fileURLWithPath: existingTarget).standardizedFileURL.path
        switch sourceKind {
        case .bundled:
            return isBundledManagedPath(existingTargetPath)
        }
    }

    private static func cleanupStaleManagedLinks(sourceKind: SourceKind, installedRoot: URL, discoveredIDs: Set<String>, log: FileLog) {
        let fileManager = FileManager.default
        guard let installedEntries = try? fileManager.contentsOfDirectory(
            at: installedRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for entry in installedEntries {
            let widgetID = entry.lastPathComponent
            guard !discoveredIDs.contains(widgetID),
                  let existingTarget = try? fileManager.destinationOfSymbolicLink(atPath: entry.path) else {
                continue
            }

            let existingTargetPath = URL(fileURLWithPath: existingTarget).standardizedFileURL.path
            let shouldRemove: Bool
            switch sourceKind {
            case .bundled:
                shouldRemove = isBundledManagedPath(existingTargetPath)
            }

            guard shouldRemove else { continue }

            do {
                try fileManager.removeItem(at: entry)
            } catch {
                log.write("Widget install: failed to remove stale \(widgetID): \(error.localizedDescription)")
            }
        }
    }

    private static func isBundledManagedPath(_ path: String) -> Bool {
        path.contains("/Contents/Resources/WidgetRuntime/widgets/")
    }

    private static func installedEntryExists(at url: URL) -> Bool {
        if FileManager.default.fileExists(atPath: url.path) {
            return true
        }

        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

@MainActor
@Observable
final class ViewManager {
    var views: [SavedView]
    var selectedViewID: UUID
    var widgetDefinitions: [WidgetDefinition]

    private var layoutsByViewID: [UUID: ViewLayout]
    private let log = FileLog()
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init() {
        jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        jsonDecoder = JSONDecoder()

        views = SavedView.defaultViews
        selectedViewID = SavedView.defaultViews[0].id
        widgetDefinitions = WidgetCatalog.discover()

        layoutsByViewID = Dictionary(
            uniqueKeysWithValues: SavedView.defaultViews.map { ($0.id, ViewLayout()) }
        )
        restorePersistedState()
    }

    var selectedView: SavedView? {
        views.first { $0.id == selectedViewID }
    }

    var selectedLayout: ViewLayout {
        guard let view = selectedView else { return ViewLayout() }
        return layout(for: view)
    }

    var selectedValidatedLayout: ValidatedViewLayout? {
        guard let view = selectedView else { return nil }
        return validatedLayout(for: view)
    }

    func reloadWidgetDefinitions() {
        widgetDefinitions = WidgetCatalog.discover(log: log)
        sanitizeAllLayouts()
    }

    func definition(for widgetID: String) -> WidgetDefinition? {
        widgetDefinitions.first(where: { $0.id == widgetID })
    }

    func layout(for view: SavedView) -> ViewLayout {
        layoutsByViewID[view.id] ?? ViewLayout()
    }

    func validatedLayout(for view: SavedView) -> ValidatedViewLayout? {
        validate(layout: layout(for: view))
    }

    func layoutSnapshot() -> [UUID: ViewLayout] {
        layoutsByViewID
    }

    func restoreLayouts(from snapshot: [UUID: ViewLayout]) {
        layoutsByViewID = snapshot
    }

    func select(_ view: SavedView) {
        selectedViewID = view.id
        persistState()
    }

    func addView(name: String, icon: String = "square.grid.2x2.fill") {
        let view = SavedView(name: name, icon: icon)
        views.append(view)
        layoutsByViewID[view.id] = ViewLayout()
        selectedViewID = view.id
        persistState()
    }

    func removeView(_ view: SavedView) {
        guard views.count > 1 else { return }
        views.removeAll { $0.id == view.id }
        layoutsByViewID.removeValue(forKey: view.id)
        if selectedViewID == view.id {
            selectedViewID = views[0].id
        }
        persistState()
    }

    func renameView(_ view: SavedView, to name: String) {
        if let i = views.firstIndex(where: { $0.id == view.id }) {
            views[i].name = name
            persistState()
        }
    }

    func setIcon(_ view: SavedView, to icon: String) {
        if let i = views.firstIndex(where: { $0.id == view.id }) {
            views[i].icon = icon
            persistState()
        }
    }

    func canMoveViewLeft(_ view: SavedView) -> Bool {
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return false }
        return index > 0
    }

    func canMoveViewRight(_ view: SavedView) -> Bool {
        guard let index = views.firstIndex(where: { $0.id == view.id }) else { return false }
        return index < views.index(before: views.endIndex)
    }

    func moveViewLeft(_ view: SavedView) {
        move(view, by: -1)
    }

    func moveViewRight(_ view: SavedView) {
        move(view, by: 1)
    }

    func persistCurrentState() {
        persistState()
    }

    func occupancyForSelectedView() -> [UUID?] {
        selectedValidatedLayout?.occupancy ?? Array(repeating: nil, count: ViewLayout.columnCount)
    }

    func addWidget(_ definition: WidgetDefinition, at column: Int, in view: SavedView? = nil) {
        let targetView = view ?? selectedView
        guard let targetView else { return }

        var layout = normalizedPackedLayout(for: layout(for: targetView))
        let usedColumns = totalUsedColumns(in: layout)
        let initialSpan = min(definition.minSpan, definition.maxSpan)
        guard usedColumns + initialSpan <= ViewLayout.columnCount else { return }

        let widget = WidgetInstance(widgetID: definition.id, startColumn: usedColumns, span: initialSpan)
        layout.widgets.append(widget)
        setLayout(packedLayout(for: layout.widgets), for: targetView)
    }

    func removeWidget(_ widgetID: UUID, in view: SavedView? = nil) {
        let targetView = view ?? selectedView
        guard let targetView else { return }

        var layout = normalizedPackedLayout(for: layout(for: targetView))
        layout.widgets.removeAll { $0.id == widgetID }
        setLayout(packedLayout(for: layout.widgets), for: targetView)
    }

    func widget(id: UUID, in view: SavedView? = nil) -> WidgetInstance? {
        let targetView = view ?? selectedView
        guard let targetView else { return nil }
        return layout(for: targetView).widgets.first(where: { $0.id == id })
    }

    func definition(for widget: WidgetInstance) -> WidgetDefinition? {
        definition(for: widget.widgetID)
    }

    func availableSpans(for widgetID: UUID, in view: SavedView? = nil) -> [Int] {
        guard let widget = widget(id: widgetID, in: view),
              let definition = definition(for: widget) else { return [] }
        return Array(definition.minSpan...definition.maxSpan)
    }

    func canSetSpan(_ span: Int, for widgetID: UUID, in view: SavedView? = nil) -> Bool {
        proposedResize(widgetID: widgetID, to: span, in: view) != nil
    }

    func setSpan(_ span: Int, for widgetID: UUID, in view: SavedView? = nil) {
        guard let targetView = view ?? selectedView,
              let proposed = proposedResize(widgetID: widgetID, to: span, in: targetView) else { return }
        setLayout(proposed.layout, for: targetView)
    }

    func canSwapWidget(_ widgetID: UUID, direction: MoveDirection, in view: SavedView? = nil) -> Bool {
        proposedSwap(widgetID: widgetID, direction: direction, in: view) != nil
    }

    func swapWidget(_ widgetID: UUID, direction: MoveDirection, in view: SavedView? = nil) {
        guard let targetView = view ?? selectedView,
              let proposed = proposedSwap(widgetID: widgetID, direction: direction, in: targetView) else { return }
        setLayout(proposed.layout, for: targetView)
    }

    func isColumnEmpty(_ column: Int, in view: SavedView? = nil) -> Bool {
        let targetView = view ?? selectedView
        guard let targetView, let occupancy = validatedLayout(for: targetView)?.occupancy,
              occupancy.indices.contains(column) else { return false }
        return occupancy[column] == nil
    }

    func widgetStartColumn(for widgetID: UUID, in view: SavedView? = nil) -> Int? {
        widget(id: widgetID, in: view)?.startColumn
    }

    func resetDefaultLayouts() {
        layoutsByViewID[SavedView.homeID] = defaultLayout(for: SavedView.homeID)
        layoutsByViewID[SavedView.focusID] = defaultLayout(for: SavedView.focusID)
        layoutsByViewID[SavedView.planID] = defaultLayout(for: SavedView.planID)
    }

    private func sanitizeAllLayouts() {
        for view in views {
            let sanitized = sanitize(layout: layout(for: view))
            layoutsByViewID[view.id] = sanitized
        }
    }

    private func sanitize(layout: ViewLayout) -> ViewLayout {
        let widgets = layout.widgets.map { widget -> WidgetInstance in
            var sanitized = widget
            if let definition = definition(for: widget.widgetID) {
                sanitized.span = min(max(widget.span, definition.minSpan), definition.maxSpan)
            }
            return sanitized
        }
        return packedLayout(for: widgets.sorted { $0.startColumn < $1.startColumn })
    }

    private func spanBounds(for widget: WidgetInstance) -> ClosedRange<Int> {
        if let definition = definition(for: widget.widgetID) {
            return definition.minSpan...definition.maxSpan
        }

        // Keep temporarily unavailable widgets visible in-place until discovery recovers.
        let preservedSpan = min(max(widget.span, 1), ViewLayout.columnCount)
        return preservedSpan...preservedSpan
    }

    private func proposedResize(widgetID: UUID, to span: Int, in view: SavedView?) -> ValidatedViewLayout? {
        let targetView = view ?? selectedView
        guard let targetView,
              var layout = validatedLayout(for: targetView)?.layout,
              let index = layout.widgets.firstIndex(where: { $0.id == widgetID }) else { return nil }

        layout = normalizedPackedLayout(for: layout)

        let widget = layout.widgets[index]
        guard let definition = definition(for: widget.widgetID) else { return nil }
        guard span >= definition.minSpan, span <= definition.maxSpan else { return nil }

        if span == widget.span {
            return validate(layout: packedLayout(for: layout.widgets))
        }

        layout.widgets[index].span = span
        guard totalUsedColumns(in: layout) <= ViewLayout.columnCount else { return nil }
        return validate(layout: packedLayout(for: layout.widgets))
    }

    private func proposedSwap(widgetID: UUID, direction: MoveDirection, in view: SavedView?) -> ValidatedViewLayout? {
        let targetView = view ?? selectedView
        guard let targetView else { return nil }

        let sortedWidgets = normalizedPackedLayout(for: layout(for: targetView)).widgets

        guard let current = sortedWidgets.first(where: { $0.id == widgetID }),
              let neighbor = neighborWidget(for: current, direction: direction, in: sortedWidgets) else { return nil }

        var reorderedWidgets = sortedWidgets
        guard let currentIndex = reorderedWidgets.firstIndex(where: { $0.id == current.id }),
              let neighborIndex = reorderedWidgets.firstIndex(where: { $0.id == neighbor.id }) else { return nil }
        reorderedWidgets.swapAt(currentIndex, neighborIndex)
        return validate(layout: packedLayout(for: reorderedWidgets))
    }

    private func neighborWidget(for widget: WidgetInstance, direction: MoveDirection, in widgets: [WidgetInstance]) -> WidgetInstance? {
        let sorted = widgets.sorted { $0.startColumn < $1.startColumn }
        guard let index = sorted.firstIndex(where: { $0.id == widget.id }) else { return nil }

        switch direction {
        case .left:
            guard index > 0 else { return nil }
            return sorted[index - 1]
        case .right:
            guard index < sorted.index(before: sorted.endIndex) else { return nil }
            return sorted[index + 1]
        }
    }

    private func setLayout(_ layout: ViewLayout, for view: SavedView) {
        guard let validated = validate(layout: layout) else {
            assertionFailure("Attempted to save invalid layout for \(view.name)")
            return
        }

        layoutsByViewID[view.id] = validated.layout
    }

    private func move(_ view: SavedView, by offset: Int) {
        guard let currentIndex = views.firstIndex(where: { $0.id == view.id }) else { return }
        let destinationIndex = currentIndex + offset
        guard views.indices.contains(destinationIndex) else { return }
        views.swapAt(currentIndex, destinationIndex)
        persistState()
    }

    private func restorePersistedState() {
        let defaults = defaultState()
        let restoredState = loadPersistedState() ?? defaults
        applyRestoredState(restoredState)
    }

    private func defaultState() -> PersistedViewStateSnapshot {
        var defaultLayouts = Dictionary(
            uniqueKeysWithValues: SavedView.defaultViews.map { ($0.id, ViewLayout()) }
        )
        defaultLayouts[SavedView.homeID] = defaultLayout(for: SavedView.homeID)
        defaultLayouts[SavedView.focusID] = defaultLayout(for: SavedView.focusID)
        defaultLayouts[SavedView.planID] = defaultLayout(for: SavedView.planID)

        return PersistedViewStateSnapshot(
            views: SavedView.defaultViews,
            selectedViewID: SavedView.defaultViews[0].id,
            layoutsByViewID: defaultLayouts
        )
    }

    private func loadPersistedState() -> PersistedViewStateSnapshot? {
        let snapshotURL = RepoPaths.savedViewsSnapshotURL
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: snapshotURL)
            return try jsonDecoder.decode(PersistedViewStateSnapshot.self, from: data)
        } catch {
            log.write("Saved views: failed to load persisted state: \(error.localizedDescription)")
            return nil
        }
    }

    private func applyRestoredState(_ snapshot: PersistedViewStateSnapshot) {
        var restoredViews = snapshot.views
        var restoredLayouts = snapshot.layoutsByViewID

        for defaultView in SavedView.defaultViews {
            if !restoredViews.contains(where: { $0.id == defaultView.id }) {
                restoredViews.append(defaultView)
                restoredLayouts[defaultView.id] = defaultLayout(for: defaultView.id)
            }
        }

        if restoredViews.isEmpty {
            restoredViews = SavedView.defaultViews
        }

        views = restoredViews
        layoutsByViewID = Dictionary(
            uniqueKeysWithValues: restoredViews.map { view in
                let layout = restoredLayouts[view.id] ?? defaultLayout(for: view.id)
                return (view.id, layout)
            }
        )

        sanitizeAllLayouts()

        if views.contains(where: { $0.id == snapshot.selectedViewID }) {
            selectedViewID = snapshot.selectedViewID
        } else {
            selectedViewID = views.first?.id ?? SavedView.defaultViews[0].id
        }
    }

    private func persistState() {
        let snapshot = PersistedViewStateSnapshot(
            views: views,
            selectedViewID: selectedViewID,
            layoutsByViewID: layoutsByViewID
        )

        do {
            try FileManager.default.createDirectory(at: RepoPaths.applicationSupportRoot, withIntermediateDirectories: true)
            let data = try jsonEncoder.encode(snapshot)
            try data.write(to: RepoPaths.savedViewsSnapshotURL, options: .atomic)
        } catch {
            log.write("Saved views: failed to persist state: \(error.localizedDescription)")
        }
    }

    private func totalUsedColumns(in layout: ViewLayout) -> Int {
        layout.widgets.reduce(0) { $0 + $1.span }
    }

    private func normalizedPackedLayout(for layout: ViewLayout) -> ViewLayout {
        packedLayout(for: layout.widgets.sorted { lhs, rhs in
            if lhs.startColumn == rhs.startColumn {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.startColumn < rhs.startColumn
        })
    }

    private func packedLayout(for widgets: [WidgetInstance]) -> ViewLayout {
        var packedWidgets: [WidgetInstance] = []
        var nextStart = 0

        for var widget in widgets {
            widget.startColumn = nextStart
            packedWidgets.append(widget)
            nextStart += widget.span
        }

        return ViewLayout(widgets: packedWidgets)
    }

    func validate(layout: ViewLayout) -> ValidatedViewLayout? {
        var occupancy = Array<UUID?>(repeating: nil, count: ViewLayout.columnCount)

        for widget in layout.widgets {
            let allowedSpans = spanBounds(for: widget)
            guard allowedSpans.contains(widget.span) else { return nil }
            guard widget.startColumn >= 0 else { return nil }
            let endColumn = widget.startColumn + widget.span
            guard endColumn <= ViewLayout.columnCount else { return nil }

            for column in widget.startColumn..<endColumn {
                if occupancy[column] != nil {
                    return nil
                }
                occupancy[column] = widget.id
            }
        }

        return ValidatedViewLayout(layout: layout, occupancy: occupancy)
    }

    private func defaultLayout(for viewID: UUID) -> ViewLayout {
        func widget(_ id: String, _ start: Int, _ span: Int) -> WidgetInstance? {
            guard let definition = definition(for: id) else { return nil }
            return WidgetInstance(widgetID: definition.id, startColumn: start, span: min(max(span, definition.minSpan), definition.maxSpan))
        }

        let widgets: [WidgetInstance]
        switch viewID {
        case SavedView.homeID:
            widgets = []
        default:
            widgets = []
        }

        return packedLayout(for: widgets)
    }

    static let availableIcons = [
        "house.fill", "chart.bar.fill", "square.grid.2x2.fill",
        "star.fill", "bookmark.fill", "folder.fill",
        "tray.fill", "clock.fill", "calendar",
        "checkmark.circle.fill", "bell.fill", "gear",
        "person.fill", "heart.fill", "bolt.fill",
        "music.note", "gamecontroller.fill", "paintbrush.fill",
        "terminal.fill", "doc.text.fill", "globe",
    ]
}

enum MoveDirection {
    case left
    case right
}
