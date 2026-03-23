import AppKit
import SwiftUI

struct NotchContentView: View {
    var vm: NotchViewModel

    private var currentWidth: CGFloat {
        vm.isExpanded ? vm.expandedWidth : vm.notchWidth - 2
    }

    private var currentHeight: CGFloat {
        vm.isExpanded ? vm.expandedHeight : vm.notchHeight
    }

    private var headerLaneWidth: CGFloat {
        max(0, (vm.expandedWidth - vm.notchWidth) / 2)
    }

    private let headerRowHeight: CGFloat = 44
    private let showsHeaderLaneDebug = false

    var body: some View {
        VStack(spacing: 0) {
            if vm.isExpanded {
                expandedContent
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: 0.2).delay(0.15)),
                        removal: .opacity.animation(.linear(duration: 0))
                    ))
            }
        }
        .frame(width: currentWidth, height: currentHeight)
        .background(
            NotchShape(
                topCornerRadius: 0,
                bottomCornerRadius: vm.isExpanded ? 20 : (vm.isElevated ? 12 : 8)
            )
            .fill(.black)
        )
        .shadow(
            color: .white.opacity(vm.isElevated ? 0.5 : 0),
            radius: vm.isElevated ? 8 : 0
        )
        .scaleEffect(
            vm.isExpanded ? 1.0 : (vm.isElevated ? 1.075 : 1.0),
            anchor: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var expandedContent: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(showsHeaderLaneDebug ? Color.red.opacity(0.18) : .clear)

                    ZStack(alignment: .leading) {
                        ViewSwitcher(viewManager: vm.viewManager, vm: vm)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .frame(width: max(0, headerLaneWidth - 24), height: max(0, headerRowHeight - 8), alignment: .leading)
                    .clipped()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .frame(width: headerLaneWidth, height: headerRowHeight)
                .clipped()

                Rectangle()
                    .fill(showsHeaderLaneDebug ? Color.green.opacity(0.2) : .clear)
                    .frame(width: vm.notchWidth, height: headerRowHeight)

                ZStack(alignment: .trailing) {
                    Rectangle()
                        .fill(showsHeaderLaneDebug ? Color.blue.opacity(0.18) : .clear)

                    HStack(spacing: 6) {
                        HeaderAccessoryButton(
                            activeSymbol: "pin.fill",
                            inactiveSymbol: "pin",
                            tint: Color(red: 0.98, green: 0.39, blue: 0.43),
                            isActive: vm.isViewPinned,
                            inactiveRotation: .degrees(45)
                        ) {
                            vm.togglePinnedView()
                        }

                        HeaderAccessoryButton(activeSymbol: "gearshape.fill") {}
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .frame(width: headerLaneWidth, height: headerRowHeight)
                .clipped()
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            // Widget area below the notch
            VStack {
                if let view = vm.viewManager.selectedView {
                    Text(view.name)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, headerRowHeight + 8)

            // Rename overlay — covers entire expanded area
            if vm.isRenamingView {
                RenameViewDialog(vm: vm)
            }
        }
    }
}

private struct HeaderAccessoryButton: View {
    var activeSymbol: String
    var inactiveSymbol: String?
    var tint: Color = .white
    var isActive = false
    var activeRotation: Angle = .zero
    var inactiveRotation: Angle = .zero
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isActive ? activeSymbol : (inactiveSymbol ?? activeSymbol))
                .font(.system(size: 11, weight: .semibold))
                .rotationEffect(isActive ? activeRotation : inactiveRotation)
                .foregroundStyle((isActive ? tint : .white).opacity(isActive ? 0.95 : 0.72))
                .frame(width: 26, height: 26)
                .background(
                    Circle()
                        .fill(isActive ? tint.opacity(0.18) : .white.opacity(0.06))
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            isActive ? tint.opacity(0.4) : .white.opacity(0.06),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

struct RenameViewDialog: View {
    var vm: NotchViewModel
    @State private var escMonitor: Any?

    private var selectedIcon: String {
        vm.viewManager.selectedView?.icon ?? "pencil"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: selectedIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 24)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    RenameTextField(
                        text: Bindable(vm).renameViewName,
                        placeholder: "View name",
                        onCommit: commit,
                        onCancel: cancel,
                        onFrameChange: updateTextFieldFrame
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.34))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: 6) {
                    KeycapLabel("esc")
                    Text("cancel")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))

                    Spacer(minLength: 0)

                    KeycapLabel("return")
                    Text("rename")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(width: 300)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.74))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.24), radius: 16, y: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            // Enable keyboard on the panel
            if let panel = NotchPanel.contentPanel {
                panel.needsKeyInput = true
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    cancel()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escMonitor {
                NSEvent.removeMonitor(monitor)
                escMonitor = nil
            }
            vm.renameViewFieldScreenRect = .zero
            if let panel = NotchPanel.contentPanel {
                panel.needsKeyInput = false
            }
        }
    }

    private func commit() {
        let trimmed = vm.renameViewName.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let view = vm.viewManager.selectedView {
            vm.viewManager.renameView(view, to: trimmed)
        }
        vm.isRenamingView = false
    }

    private func cancel() {
        vm.isRenamingView = false
    }

    private func updateTextFieldFrame(_ frame: CGRect) {
        vm.renameViewFieldScreenRect = frame
    }
}

private struct KeycapLabel: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(0.06), lineWidth: 1)
            )
    }
}

private struct RenameTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    var onFrameChange: (CGRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel, onFrameChange: onFrameChange)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.stringValue = text
        textField.placeholderString = placeholder
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.isEditable = true
        textField.isSelectable = true
        textField.isEnabled = true
        textField.font = .systemFont(ofSize: 12, weight: .medium)
        textField.textColor = .white
        textField.cell?.usesSingleLineMode = true
        textField.cell?.lineBreakMode = .byTruncatingTail
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onCancel = onCancel
        context.coordinator.onFrameChange = onFrameChange

        if textField.stringValue != text {
            textField.stringValue = text
        }

        if let window = textField.window {
            let rectInWindow = textField.convert(textField.bounds, to: nil)
            let rectOnScreen = window.convertToScreen(rectInWindow)
            context.coordinator.onFrameChange(rectOnScreen)
        }

        context.coordinator.focusIfNeeded(textField)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onCommit: () -> Void
        var onCancel: () -> Void
        var onFrameChange: (CGRect) -> Void
        var hasFocused = false
        var focusAttempts = 0

        init(
            text: Binding<String>,
            onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void,
            onFrameChange: @escaping (CGRect) -> Void
        ) {
            _text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
            self.onFrameChange = onFrameChange
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func focusIfNeeded(_ textField: NSTextField) {
            guard !hasFocused, focusAttempts < 8 else { return }

            let attempt = focusAttempts
            focusAttempts += 1

            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.05)) {
                guard !self.hasFocused, let window = textField.window else { return }

                _ = window.makeFirstResponder(nil)
                guard window.makeFirstResponder(textField) else {
                    self.focusIfNeeded(textField)
                    return
                }

                guard let editor = window.fieldEditor(true, for: textField) as? NSTextView else {
                    self.focusIfNeeded(textField)
                    return
                }

                editor.insertionPointColor = .white
                editor.selectedRange = NSRange(location: 0, length: textField.stringValue.count)
                self.hasFocused = true
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommit()
                return true
            }

            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                onCancel()
                return true
            }

            return false
        }
    }
}

struct NotchBlurView: View {
    var vm: NotchViewModel

    var body: some View {
        EmptyView()
    }
}
