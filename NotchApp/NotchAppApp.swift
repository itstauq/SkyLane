import SwiftUI
import Carbon.HIToolbox

@main
struct NotchAppApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let logger = FileLog()
    private let keepsCollapsedNotchVisibleForDemo = false
    private var moveMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var notchRect: CGRect = .zero
    private var expandedRect: CGRect = .zero
    private var notchPanel: NotchPanel?
    private var blurPanel: NotchPanel?
    private let vm = NotchViewModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.write("App launched")
        registerWithLaunchServices()
        registerURLHandler()
        setupStatusBar()
        setupNotch()
        startMouseMonitor()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        vm.refreshWidgetDefinitions()
    }

    func applicationWillTerminate(_ notification: Notification) {
        vm.flushStorageWrites()
        vm.widgetRuntime.shutdown()
        if let monitor = moveMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        NSAppleEventManager.shared().removeEventHandler(
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
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
            guard let self else { return }
            let mouse = NSEvent.mouseLocation

            // When expanded, track the expanded rect for exit
            // When not expanded, track the notch rect for entry
            let checkRect = vm.isExpanded ? expandedRect : notchRect
            let inside = contains(checkRect, mouse)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if inside != vm.isMouseInside {
                    if inside {
                        notchPanel?.alphaValue = 1
                        blurPanel?.alphaValue = 1
                        vm.mouseEntered()
                    } else {
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
            notchPanel?.alphaValue = 1
            blurPanel?.alphaValue = 1
            vm.clicked()
        } else if vm.isExpanded && !contains(expandedRect, mouse) {
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
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "NotchApp")
        }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
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
