import AppKit
import Combine
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

@MainActor
final class AppUpdater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = AppUpdater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var automaticallyDownloadsUpdates = false
    @Published private(set) var allowsAutomaticUpdates = false

#if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
    private var observationCancellables: Set<AnyCancellable> = []

    var updater: SPUUpdater {
        updaterController.updater
    }
#endif

    var canConfigureAutomaticDownloads: Bool {
        automaticallyChecksForUpdates && allowsAutomaticUpdates
    }

    private override init() {
#if canImport(Sparkle)
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
#endif
        super.init()

#if canImport(Sparkle)
        synchronizeState()
        observeUpdaterState()
#endif
    }

    func performCheckForUpdates() {
#if canImport(Sparkle)
        updater.checkForUpdates()
#endif
    }

    @objc func checkForUpdates(_ sender: Any?) {
        performCheckForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ newValue: Bool) {
#if canImport(Sparkle)
        guard updater.automaticallyChecksForUpdates != newValue else { return }
        updater.automaticallyChecksForUpdates = newValue
        synchronizeState()
#else
        automaticallyChecksForUpdates = newValue
#endif
    }

    func setAutomaticallyDownloadsUpdates(_ newValue: Bool) {
#if canImport(Sparkle)
        let targetValue = canConfigureAutomaticDownloads ? newValue : false
        guard updater.automaticallyDownloadsUpdates != targetValue else { return }
        updater.automaticallyDownloadsUpdates = targetValue
        synchronizeState()
#else
        automaticallyDownloadsUpdates = newValue
#endif
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates(_:)) else {
            return true
        }

        return canCheckForUpdates
    }

#if canImport(Sparkle)
    private func observeUpdaterState() {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronizeState()
            }
            .store(in: &observationCancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronizeState()
            }
            .store(in: &observationCancellables)

        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronizeState()
            }
            .store(in: &observationCancellables)

        updater.publisher(for: \.allowsAutomaticUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.synchronizeState()
            }
            .store(in: &observationCancellables)
    }

    private func synchronizeState() {
        canCheckForUpdates = updater.canCheckForUpdates
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        allowsAutomaticUpdates = updater.allowsAutomaticUpdates
    }
#endif
}
