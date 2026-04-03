import SwiftUI
import Carbon.HIToolbox

@main
struct NotchAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            AppSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let toggleHotKeyID: UInt32 = 1

    private var statusItem: NSStatusItem?
    private let logger = FileLog()
    private let keepsCollapsedNotchVisibleForDemo = false
    private var moveMonitor: Any?
    private var localMoveMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverOpenTask: Task<Void, Never>?
    private var notchRect: CGRect = .zero
    private var expandedRect: CGRect = .zero
    private var notchPanel: NotchPanel?
    private var blurPanel: NotchPanel?
    private let vm = NotchViewModel()
    private var menuBarIconPreferenceObserver: NSObjectProtocol?
    private var keyboardShortcutsPreferenceObserver: NSObjectProtocol?
    private var keyboardShortcutPreferenceObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.write("App launched")
        registerWithLaunchServices()
        registerURLHandler()
        updateStatusBarVisibility()
        observeMenuBarIconPreference()
        observeKeyboardShortcutsPreference()
        observeKeyboardShortcutPreference()
        setupNotch()
        registerHotKeyIfNeeded()
        startMouseMonitor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        vm.refreshWidgetDefinitions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        vm.flushStorageWrites()
        vm.widgetRuntime.shutdown()
        if let monitor = moveMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMoveMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        hoverOpenTask?.cancel()
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
        if let menuBarIconPreferenceObserver {
            NotificationCenter.default.removeObserver(menuBarIconPreferenceObserver)
        }
        if let keyboardShortcutsPreferenceObserver {
            NotificationCenter.default.removeObserver(keyboardShortcutsPreferenceObserver)
        }
        if let keyboardShortcutPreferenceObserver {
            NotificationCenter.default.removeObserver(keyboardShortcutPreferenceObserver)
        }
        unregisterHotKey()
        logger.write("App exiting")
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else {
            return
        }

        handleDevelopmentURL(url)
    }

    private func setupNotch() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            logger.write("No notch screen found")
            return
        }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let w = screen.frame.width - left - right
        let h = screen.safeAreaInsets.top
        notchRect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - h,
            width: w, height: h
        )
        vm.notchWidth = w
        vm.notchHeight = h
        vm.screenWidth = screen.frame.width

        // Expanded rect for click-outside detection
        let ew = vm.expandedWidth
        let eh = vm.expandedHeight
        expandedRect = CGRect(
            x: screen.frame.midX - ew / 2,
            y: screen.frame.maxY - eh,
            width: ew, height: eh
        )
        logger.write("Notch rect: \(notchRect)")

        // Panel sizing — room for expanded state
        let panelW = ew + 40
        let panelH = eh + 20
        let panelRect = NSRect(
            x: screen.frame.midX - panelW / 2,
            y: screen.frame.maxY - panelH,
            width: panelW, height: panelH
        )

        // Back panel: progressive blur glow (behind the notch)
        let blur = NotchPanel(
            contentRect: panelRect,
            level: .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1),
            kind: .blur
        )
        blur.setView(NotchBlurView(vm: vm))
        blur.alphaValue = keepsCollapsedNotchVisibleForDemo ? 1 : 0
        blur.orderFrontRegardless()
        blurPanel = blur

        // Front panel: the notch shape itself
        let panel = NotchPanel(
            contentRect: panelRect,
            level: .init(rawValue: NSWindow.Level.mainMenu.rawValue + 2),
            kind: .content
        )
        panel.setView(NotchContentView(vm: vm))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        notchPanel = panel
    }

    private func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }

    private func startMouseMonitor() {
        // Mouse move — hover for peek, hover-exit for collapse
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.handleMouseMove()
        }

        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMove()
            return event
        }

        // Click inside notch → expand (global: clicks in other windows)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleClick(at: mouse)
            }
        }

        // Local: clicks on our own panel
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            let mouse = NSEvent.mouseLocation
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.handleClick(at: mouse)
            }
            return event
        }
    }

    private func handleMouseMove() {
        let mouse = NSEvent.mouseLocation

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // When expanded, track the expanded rect for exit
            // When not expanded, track the notch rect for entry
            let checkRect = vm.isExpanded ? expandedRect : notchRect
            let inside = contains(checkRect, mouse)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if inside != vm.isMouseInside {
                    if inside {
                        hoverOpenTask?.cancel()
                        notchPanel?.alphaValue = 1
                        blurPanel?.alphaValue = 1
                        vm.mouseEntered()
                        if Preferences.openNotchMode == .hover {
                            hoverOpenTask = Task { @MainActor [weak self] in
                                guard let self else { return }
                                try? await Task.sleep(for: .milliseconds(Int(Preferences.hoverDelay * 1000)))
                                guard !Task.isCancelled, self.vm.isMouseInside, !self.vm.isExpanded else { return }
                                self.vm.clicked()
                            }
                        }
                    } else {
                        hoverOpenTask?.cancel()
                        vm.mouseExited()
                        // Hide panel after collapse animation
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(500))
                            guard let self, !self.vm.isMouseInside, !self.vm.isExpanded else { return }
                            if !self.keepsCollapsedNotchVisibleForDemo {
                                self.notchPanel?.alphaValue = 0
                                self.blurPanel?.alphaValue = 0
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleClick(at mouse: CGPoint) {
        if vm.isRenamingView {
            if contains(vm.renameViewFieldScreenRect, mouse) {
                return
            }

            vm.isRenamingView = false
            return
        }

        if vm.isEditingLayout && vm.isExpanded && !contains(expandedRect, mouse) {
            vm.attemptExitEditMode()
            return
        }

        if !vm.isExpanded && contains(notchRect, mouse) {
            hoverOpenTask?.cancel()
            notchPanel?.alphaValue = 1
            blurPanel?.alphaValue = 1
            vm.clicked()
        } else if vm.isExpanded && !contains(expandedRect, mouse) {
            hoverOpenTask?.cancel()
            vm.mouseExited()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.vm.isExpanded else { return }
                if !self.keepsCollapsedNotchVisibleForDemo {
                    self.notchPanel?.alphaValue = 0
                    self.blurPanel?.alphaValue = 0
                }
            }
        }
    }

    private func setupStatusBar() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchApp")
        }
        let menu = NSMenu()
        menu.addItem(makeStatusMenuItem(
            title: "Settings",
            systemImageName: "gearshape",
            action: #selector(openSettings),
            keyEquivalent: ","
        ))
        menu.addItem(makeStatusMenuItem(
            title: "About",
            systemImageName: "info.circle",
            action: #selector(openAbout),
            keyEquivalent: ""
        ))
        menu.addItem(.separator())
        menu.addItem(makeStatusMenuItem(
            title: "Quit",
            systemImageName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        ))
        menu.items.forEach { $0.target = self }
        statusItem?.menu = menu
    }

    private func makeStatusMenuItem(
        title: String,
        systemImageName: String,
        action: Selector,
        keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.image = NSImage(
            systemSymbolName: systemImageName,
            accessibilityDescription: title
        )
        return item
    }

    private func removeStatusBar() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func updateStatusBarVisibility() {
        if Preferences.isMenuBarIconEnabled {
            setupStatusBar()
        } else {
            removeStatusBar()
        }
    }

    private func observeMenuBarIconPreference() {
        menuBarIconPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .menuBarIconPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateStatusBarVisibility()
            }
        }
    }

    private func observeKeyboardShortcutsPreference() {
        keyboardShortcutsPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .keyboardShortcutsPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.registerHotKeyIfNeeded()
            }
        }
    }

    private func observeKeyboardShortcutPreference() {
        keyboardShortcutPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .keyboardShortcutPreferenceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.registerHotKeyIfNeeded()
            }
        }
    }

    private func registerHotKeyIfNeeded() {
        unregisterHotKey()
        guard Preferences.keyboardShortcutsEnabled else { return }

        if hotKeyHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let callback: EventHandlerUPP = { _, event, userData in
                guard let userData, let event else { return noErr }
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                return appDelegate.handleHotKeyEvent(event)
            }

            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &hotKeyHandlerRef
            )
        }

        var hotKeyID = EventHotKeyID(signature: fourCharCode("NAPP"), id: Self.toggleHotKeyID)
        guard let shortcut = Preferences.toggleNotchShortcut else { return }
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.id == Self.toggleHotKeyID else {
            return noErr
        }

        toggleNotchFromShortcut()
        return noErr
    }

    private func toggleNotchFromShortcut() {
        hoverOpenTask?.cancel()

        if vm.isExpanded {
            vm.mouseExited()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.vm.isExpanded else { return }
                if !self.keepsCollapsedNotchVisibleForDemo {
                    self.notchPanel?.alphaValue = 0
                    self.blurPanel?.alphaValue = 0
                }
            }
            return
        }

        notchPanel?.alphaValue = 1
        blurPanel?.alphaValue = 1
        vm.clicked()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func openSettings() {
        AppSettingsWindow.open(tab: .general)
    }

    @objc private func openAbout() {
        AppSettingsWindow.open(tab: .about)
    }

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func registerWithLaunchServices() {
        let registerURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        guard FileManager.default.fileExists(atPath: registerURL.path) else {
            return
        }

        let process = Process()
        process.executableURL = registerURL
        process.arguments = ["-f", Bundle.main.bundleURL.path]
        do {
            try process.run()
        } catch {
            logger.write("LaunchServices registration failed: \(error.localizedDescription)")
        }
    }

    private func handleDevelopmentURL(_ url: URL) {
        guard url.scheme == "notch",
              url.host == "cli" else {
            return
        }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2 else { return }

        let widgetID = components[0]
        let event = components[1]
        let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let info = urlComponents?.queryItems?.first(where: { $0.name == "info" })?.value

        logger.write("CLI event: \(event) for \(widgetID)")
        vm.handleDevelopmentEvent(widgetID: widgetID, event: event, info: info)
    }
}

private func fourCharCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { ($0 << 8) | OSType($1) }
}

struct FileLog {
    private let url: URL = {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let logDirectory = baseURL.appendingPathComponent("NotchApp", isDirectory: true)
        return logDirectory.appendingPathComponent("notchapp.log")
    }()

    func write(_ message: String) {
        let line = "[\(Self.fmt.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: url.path, contents: data)
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
