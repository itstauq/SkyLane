import SwiftUI
import Carbon.HIToolbox

@main
struct SkylaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appUpdater = AppUpdater.shared

    var body: some Scene {
        Settings {
            AppSettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let toggleHotKeyID: UInt32 = 1

    private var statusItem: NSStatusItem?
    private let logger = FileLog()
    private let keepsCollapsedLaneVisibleForDemo = false
    private var moveMonitor: Any?
    private var localMoveMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverOpenTask: Task<Void, Never>?
    private var laneRect: CGRect = .zero
    private var expandedRect: CGRect = .zero
    private var lanePanel: LanePanel?
    private var blurPanel: LanePanel?
    private let vm = LaneViewModel()
    private var menuBarIconPreferenceObserver: NSObjectProtocol?
    private var keyboardShortcutsPreferenceObserver: NSObjectProtocol?
    private var keyboardShortcutPreferenceObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var statusMenuShortcutMonitor: Any?
    private let appUpdater = AppUpdater.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.write("App launched")
        Preferences.ensureLaunchAtLoginDefault()
        registerWithLaunchServices()
        registerURLHandler()
        updateStatusBarVisibility()
        observeMenuBarIconPreference()
        observeKeyboardShortcutsPreference()
        observeKeyboardShortcutPreference()
        setupLane()
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
        removeStatusMenuShortcutMonitor()
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

    private func setupLane() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            logger.write("No supported top-edge screen found")
            return
        }
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let w = screen.frame.width - left - right
        let h = screen.safeAreaInsets.top
        laneRect = CGRect(
            x: screen.frame.midX - w / 2,
            y: screen.frame.maxY - h,
            width: w, height: h
        )
        vm.laneWidth = w
        vm.laneHeight = h
        vm.screenWidth = screen.frame.width

        // Expanded rect for click-outside detection
        let ew = vm.expandedWidth
        let eh = vm.expandedHeight
        expandedRect = CGRect(
            x: screen.frame.midX - ew / 2,
            y: screen.frame.maxY - eh,
            width: ew, height: eh
        )
        logger.write("Lane rect: \(laneRect)")

        // Panel sizing — room for expanded state
        let panelW = ew + 40
        let panelH = eh + 20
        let panelRect = NSRect(
            x: screen.frame.midX - panelW / 2,
            y: screen.frame.maxY - panelH,
            width: panelW, height: panelH
        )

        // Back panel: progressive blur glow behind the compact surface
        let blur = LanePanel(
            contentRect: panelRect,
            level: .init(rawValue: NSWindow.Level.mainMenu.rawValue + 1),
            kind: .blur
        )
        blur.setView(LaneBlurView(vm: vm))
        blur.alphaValue = keepsCollapsedLaneVisibleForDemo ? 1 : 0
        blur.orderFrontRegardless()
        blurPanel = blur

        // Front panel: the visible lane surface
        let panel = LanePanel(
            contentRect: panelRect,
            level: .init(rawValue: NSWindow.Level.mainMenu.rawValue + 2),
            kind: .content
        )
        panel.setView(LaneContentView(vm: vm))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        lanePanel = panel
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

        // Click inside the compact surface to expand it.
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
            // When not expanded, track the compact lane rect for entry.
            let checkRect = vm.isExpanded ? expandedRect : laneRect
            let inside = contains(checkRect, mouse)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if inside != vm.isMouseInside {
                    if inside {
                        hoverOpenTask?.cancel()
                        lanePanel?.alphaValue = 1
                        blurPanel?.alphaValue = 1
                        vm.mouseEntered()
                        if Preferences.openLaneMode == .hover {
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
                            if !self.keepsCollapsedLaneVisibleForDemo {
                                self.lanePanel?.alphaValue = 0
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

        if !vm.isExpanded && contains(laneRect, mouse) {
            hoverOpenTask?.cancel()
            lanePanel?.alphaValue = 1
            blurPanel?.alphaValue = 1
            vm.clicked()
        } else if vm.isExpanded && !contains(expandedRect, mouse) {
            hoverOpenTask?.cancel()
            vm.mouseExited()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.vm.isExpanded else { return }
                if !self.keepsCollapsedLaneVisibleForDemo {
                    self.lanePanel?.alphaValue = 0
                    self.blurPanel?.alphaValue = 0
                }
            }
        }
    }

    private func setupStatusBar() {
        guard statusItem == nil else { return }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button,
           let image = (NSImage(named: "MenuBarIcon")?.copy() as? NSImage) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        refreshStatusMenu()
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
        item.target = self
        return item
    }

    private func makeExternalLinkMenuItem(
        title: String,
        systemImageName: String,
        urlString: String
    ) -> NSMenuItem {
        let item = makeStatusMenuItem(
            title: title,
            systemImageName: systemImageName,
            action: #selector(openExternalLink(_:)),
            keyEquivalent: ""
        )
        item.representedObject = urlString
        return item
    }

    private func refreshStatusMenu() {
        guard statusItem != nil else { return }
        statusItem?.menu = makeStatusMenu()
    }

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        let openSkylaneItem = makeStatusMenuItem(
            title: "Open Skylane",
            systemImageName: "macwindow",
            action: #selector(openSkylane),
            keyEquivalent: ""
        )
        applyStatusMenuShortcut(Preferences.toggleLaneShortcut, to: openSkylaneItem)
        menu.addItem(openSkylaneItem)
        menu.addItem(.separator())
        menu.addItem(makeExternalLinkMenuItem(
            title: "Send Feedback",
            systemImageName: "bubble.left.and.text.bubble.right",
            urlString: "https://github.com/itstauq/Skylane/issues"
        ))
        menu.addItem(makeExternalLinkMenuItem(
            title: "User Guide",
            systemImageName: "book.closed",
            urlString: "https://mintlify.wiki/itstauq/SkyLane"
        ))
        menu.addItem(makeExternalLinkMenuItem(
            title: "Star on GitHub",
            systemImageName: "star",
            urlString: "https://github.com/itstauq/Skylane/"
        ))
        let followUsItem = makeExternalLinkMenuItem(
            title: "Follow Us",
            systemImageName: "xmark",
            urlString: "https://x.com/itstauq"
        )
        if let image = (NSImage(named: "XLogo")?.copy() as? NSImage) {
            image.size = NSSize(width: 12, height: 12)
            image.isTemplate = true
            followUsItem.image = image
        }
        menu.addItem(followUsItem)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "Version \(appVersionString)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(makeStatusMenuItem(
            title: "About Skylane",
            systemImageName: "info.circle",
            action: #selector(openAbout),
            keyEquivalent: ""
        ))

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates",
            action: #selector(AppUpdater.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.image = NSImage(
            systemSymbolName: "arrow.trianglehead.clockwise",
            accessibilityDescription: "Check for Updates"
        )
        checkForUpdatesItem.target = appUpdater
        menu.addItem(checkForUpdatesItem)

        let settingsItem = makeStatusMenuItem(
            title: "Settings",
            systemImageName: "gearshape",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(makeStatusMenuItem(
            title: "Restart Skylane",
            systemImageName: "arrow.clockwise",
            action: #selector(restartSkylane),
            keyEquivalent: ""
        ))
        menu.addItem(makeStatusMenuItem(
            title: "Quit",
            systemImageName: "power",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        return menu
    }

    private func applyStatusMenuShortcut(_ shortcut: Preferences.KeyboardShortcut?, to item: NSMenuItem) {
        guard let shortcut,
              let keyEquivalent = keyEquivalentString(for: shortcut.keyCode) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }

        item.keyEquivalent = keyEquivalent
        item.keyEquivalentModifierMask = shortcut.modifiers.intersection([.control, .option, .shift, .command])
    }

    private func keyEquivalentString(for keyCode: UInt32) -> String? {
        switch keyCode {
        case UInt32(kVK_Return):
            return "\r"
        case UInt32(kVK_Tab):
            return "\t"
        case UInt32(kVK_Space):
            return " "
        case UInt32(kVK_Delete):
            return String(Character(UnicodeScalar(NSDeleteCharacter)!))
        case UInt32(kVK_ForwardDelete):
            return String(Character(UnicodeScalar(NSDeleteFunctionKey)!))
        case UInt32(kVK_Escape):
            return "\u{1B}"
        case UInt32(kVK_LeftArrow):
            return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case UInt32(kVK_RightArrow):
            return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case UInt32(kVK_DownArrow):
            return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        case UInt32(kVK_UpArrow):
            return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        default:
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return nil
            }

            let keyboardLayout = unsafeBitCast(layoutData, to: CFData.self)
            guard let layoutPtr = CFDataGetBytePtr(keyboardLayout) else {
                return nil
            }

            let layout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(layoutPtr))
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length).lowercased()
        }
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
        return shortVersion ?? buildVersion ?? "0.1.0"
    }

    private func removeStatusBar() {
        let hadStatusMenuShortcutMonitor = statusMenuShortcutMonitor != nil
        removeStatusMenuShortcutMonitor()
        if hadStatusMenuShortcutMonitor {
            registerHotKeyIfNeeded()
        }
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
                self?.refreshStatusMenu()
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
                self?.refreshStatusMenu()
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
        guard let shortcut = Preferences.toggleLaneShortcut else { return }
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

    private func installStatusMenuShortcutMonitor(for menu: NSMenu) {
        removeStatusMenuShortcutMonitor()
        statusMenuShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak menu] event in
            guard let self, let menu else { return event }
            guard self.matchesToggleShortcut(event) else { return event }

            menu.cancelTrackingWithoutAnimation()
            Task { @MainActor [weak self] in
                self?.openSkylane()
            }
            return nil
        }
    }

    private func removeStatusMenuShortcutMonitor() {
        if let statusMenuShortcutMonitor {
            NSEvent.removeMonitor(statusMenuShortcutMonitor)
            self.statusMenuShortcutMonitor = nil
        }
    }

    private func matchesToggleShortcut(_ event: NSEvent) -> Bool {
        guard let shortcut = Preferences.toggleLaneShortcut else { return false }
        let relevantModifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        let shortcutModifiers = shortcut.modifiers.intersection([.control, .option, .shift, .command])
        return UInt32(event.keyCode) == shortcut.keyCode && relevantModifiers == shortcutModifiers
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

        toggleLaneFromShortcut()
        return noErr
    }

    private func toggleLaneFromShortcut() {
        hoverOpenTask?.cancel()

        if vm.isExpanded {
            vm.mouseExited()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !self.vm.isExpanded else { return }
                if !self.keepsCollapsedLaneVisibleForDemo {
                    self.lanePanel?.alphaValue = 0
                    self.blurPanel?.alphaValue = 0
                }
            }
            return
        }

        lanePanel?.alphaValue = 1
        blurPanel?.alphaValue = 1
        vm.clicked()
    }

    @objc private func openSkylane() {
        hoverOpenTask?.cancel()
        lanePanel?.alphaValue = 1
        blurPanel?.alphaValue = 1

        if vm.isExpanded {
            LanePanel.contentPanel?.activateForKeyInput()
            return
        }

        vm.clicked()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func restartSkylane() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]

        do {
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            logger.write("Restart failed: \(error.localizedDescription)")
        }
    }

    @objc private func openSettings() {
        AppSettingsWindow.open(tab: .general)
    }

    @objc private func openAbout() {
        AppSettingsWindow.open(tab: .about)
    }

    @objc private func openExternalLink(_ sender: NSMenuItem) {
        guard let rawURL = sender.representedObject as? String,
              let url = URL(string: rawURL) else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        unregisterHotKey()
        installStatusMenuShortcutMonitor(for: menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu == statusItem?.menu else { return }
        removeStatusMenuShortcutMonitor()
        registerHotKeyIfNeeded()
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
        guard url.scheme == "skylane",
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
        let logDirectory = baseURL.appendingPathComponent("Skylane", isDirectory: true)
        return logDirectory.appendingPathComponent("skylane.log")
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
