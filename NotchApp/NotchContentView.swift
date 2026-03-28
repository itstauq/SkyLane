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
        .task(id: vm.viewManager.layoutSnapshot()) {
            vm.syncWidgetRuntimeLayouts()
        }
    }

    private var expandedContent: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    Color.clear

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
                    .fill(.clear)
                    .frame(width: vm.notchWidth, height: headerRowHeight)

                ZStack(alignment: .trailing) {
                    Color.clear

                    HStack(spacing: 6) {
                        if vm.isEditingLayout {
                            HeaderAccessoryButton(
                                activeSymbol: "xmark",
                                tint: Color(red: 0.98, green: 0.39, blue: 0.43),
                                isActive: true
                            ) {
                                vm.revertEditMode()
                            }
                        }

                        HeaderAccessoryButton(
                            activeSymbol: vm.isEditingLayout ? "checkmark" : "pencil",
                            inactiveLabel: "Edit",
                            tint: Color(red: 0.39, green: 0.68, blue: 0.98),
                            isActive: vm.isEditingLayout
                        ) {
                            if vm.isEditingLayout {
                                vm.saveEditMode()
                            } else {
                                vm.toggleEditMode()
                            }
                        }

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

            WidgetLayoutRow(vm: vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, headerRowHeight + 12)
                .padding(.horizontal, 18)
                .padding(.bottom, 18)

            // Rename overlay — covers entire expanded area
            if vm.isRenamingView {
                RenameViewDialog(vm: vm)
            }

            if vm.isShowingEditConfirmation {
                EditModeConfirmationDialog(vm: vm)
            }
        }
    }
}

private struct WidgetLayoutRow: View {
    var vm: NotchViewModel

    @State private var heldWidgetID: UUID?
    @State private var heldWidgetTranslation: CGFloat = 0

    private let slotSpacing: CGFloat = 12
    private let reorderThresholdFactor: CGFloat = 0.2

    var body: some View {
        GeometryReader { geometry in
            let totalGapWidth = slotSpacing * CGFloat(max(ViewLayout.columnCount - 1, 0))
            let slotWidth = max(0, (geometry.size.width - totalGapWidth) / CGFloat(ViewLayout.columnCount))
            let validatedLayout = vm.viewManager.selectedValidatedLayout
            let usedColumns = validatedLayout?.layout.widgets.reduce(0) { max($0, $1.startColumn + $1.span) } ?? 0
            let remainingColumns = max(0, ViewLayout.columnCount - usedColumns)

            if validatedLayout == nil {
                Color.clear
                    .onAppear {
                        assertionFailure("Invalid selected layout encountered during render")
                    }
            }

            ZStack(alignment: .topLeading) {
                if let validatedLayout, validatedLayout.layout.widgets.isEmpty {
                    EmptyWidgetState(vm: vm, isEditing: vm.isEditingLayout)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if vm.isEditingLayout,
                   remainingColumns > 0,
                   let validatedLayout,
                   !validatedLayout.layout.widgets.isEmpty {
                    EmptySlotMenu(vm: vm, column: usedColumns)
                        .frame(
                            width: trailingAreaWidth(remainingColumns: remainingColumns, slotWidth: slotWidth),
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                        .offset(
                            x: CGFloat(usedColumns) * (slotWidth + slotSpacing),
                            y: 0
                        )
                }

                if let validatedLayout {
                    ForEach(validatedLayout.layout.widgets) { widget in
                        let isHeld = heldWidgetID == widget.id
                        let definition = vm.viewManager.definition(for: widget)

                        WidgetCard(
                            widget: widget,
                            vm: vm,
                            isEditing: vm.isEditingLayout,
                            isHeld: isHeld,
                            minSpan: definition?.minSpan ?? 3,
                            maxSpan: definition?.maxSpan ?? ViewLayout.columnCount,
                            canSetSpan: { span in
                                vm.viewManager.canSetSpan(span, for: widget.id)
                            },
                            onSetSpan: { span in
                                vm.viewManager.setSpan(span, for: widget.id)
                            },
                            onRemove: {
                                vm.viewManager.removeWidget(widget.id)
                            },
                            onHandleDragChanged: { translation in
                                heldWidgetID = widget.id
                                heldWidgetTranslation = translation
                            },
                            onHandleDragEnded: { translation in
                                defer {
                                    heldWidgetID = nil
                                    heldWidgetTranslation = 0
                                }

                                let direction: MoveDirection = translation > 0 ? .right : .left
                                let threshold = moveThreshold(for: widget, direction: direction, slotWidth: slotWidth)
                                guard abs(translation) > threshold else { return }
                                vm.viewManager.swapWidget(widget.id, direction: direction)
                            }
                        )
                        .frame(
                            width: widgetWidth(for: widget, slotWidth: slotWidth),
                            height: geometry.size.height,
                            alignment: .topLeading
                        )
                        .clipped()
                        .offset(
                            x: widgetXOffset(for: widget, slotWidth: slotWidth),
                            y: 0
                        )
                        .offset(
                            x: isHeld
                                ? clampedWidgetDragOffset(heldWidgetTranslation, widget: widget, slotWidth: slotWidth)
                                : previewOffset(for: widget, slotWidth: slotWidth)
                        )
                        .shadow(color: .black.opacity(isHeld ? 0.26 : 0.12), radius: isHeld ? 18 : 10, y: isHeld ? 8 : 6)
                        .animation(.interpolatingSpring(duration: 0.22, bounce: 0.18), value: validatedLayout.layout.widgets)
                    }
                }
            }
        }
    }

    private func widgetWidth(for widget: WidgetInstance, slotWidth: CGFloat) -> CGFloat {
        (slotWidth * CGFloat(widget.span)) + (slotSpacing * CGFloat(max(widget.span - 1, 0)))
    }

    private func widgetXOffset(for widget: WidgetInstance, slotWidth: CGFloat) -> CGFloat {
        CGFloat(widget.startColumn) * (slotWidth + slotSpacing)
    }

    private func trailingAreaWidth(remainingColumns: Int, slotWidth: CGFloat) -> CGFloat {
        guard remainingColumns > 0 else { return 0 }
        return (slotWidth * CGFloat(remainingColumns)) + (slotSpacing * CGFloat(max(remainingColumns - 1, 0)))
    }

    private func clampedWidgetDragOffset(_ translation: CGFloat, widget: WidgetInstance, slotWidth: CGFloat) -> CGFloat {
        let direction: MoveDirection = translation > 0 ? .right : .left
        let threshold = moveThreshold(for: widget, direction: direction, slotWidth: slotWidth)
        return max(-threshold, min(translation * 0.35, threshold))
    }

    private func moveThreshold(for widget: WidgetInstance, direction: MoveDirection, slotWidth: CGFloat) -> CGFloat {
        neighborCenterDistance(for: widget, direction: direction, slotWidth: slotWidth) * reorderThresholdFactor
    }

    private func previewOffset(for widget: WidgetInstance, slotWidth: CGFloat) -> CGFloat {
        guard let heldWidgetID,
              let widgets = vm.viewManager.selectedValidatedLayout?.layout.widgets.sorted(by: { $0.startColumn < $1.startColumn }),
              let heldWidget = widgets.first(where: { $0.id == heldWidgetID }),
              heldWidget.id != widget.id,
              heldWidgetTranslation != 0 else { return 0 }

        let direction: MoveDirection = heldWidgetTranslation > 0 ? .right : .left
        let threshold = max(moveThreshold(for: heldWidget, direction: direction, slotWidth: slotWidth), 1)
        guard abs(heldWidgetTranslation) > threshold,
              let heldIndex = widgets.firstIndex(where: { $0.id == heldWidgetID }) else { return 0 }

        let neighborIndex = direction == .right ? heldIndex + 1 : heldIndex - 1
        guard widgets.indices.contains(neighborIndex),
              widgets[neighborIndex].id == widget.id else { return 0 }

        let progress = min((abs(heldWidgetTranslation) - threshold) / threshold, 1)
        let easedProgress = progress * progress * (3 - (2 * progress))
        let previewDistance = min(22, (widgetWidth(for: widget, slotWidth: slotWidth) * 0.18) + 6)

        return direction == .right
            ? -(previewDistance * easedProgress)
            : (previewDistance * easedProgress)
    }

    private func neighborCenterDistance(for widget: WidgetInstance, direction: MoveDirection, slotWidth: CGFloat) -> CGFloat {
        guard let widgets = vm.viewManager.selectedValidatedLayout?.layout.widgets.sorted(by: { $0.startColumn < $1.startColumn }),
              let index = widgets.firstIndex(where: { $0.id == widget.id }) else {
            return max(24, widgetWidth(for: widget, slotWidth: slotWidth) * 0.5)
        }

        let neighborIndex = direction == .left ? index - 1 : index + 1
        guard widgets.indices.contains(neighborIndex) else {
            return max(24, widgetWidth(for: widget, slotWidth: slotWidth) * 0.5)
        }

        let neighbor = widgets[neighborIndex]
        let currentWidth = widgetWidth(for: widget, slotWidth: slotWidth)
        let neighborWidth = widgetWidth(for: neighbor, slotWidth: slotWidth)

        return max(24, ((currentWidth + neighborWidth) / 2) + (slotSpacing / 2))
    }
}

private struct EmptySlotMenu: View {
    var vm: NotchViewModel
    var column: Int

    var body: some View {
            Menu {
                ForEach(vm.viewManager.widgetDefinitions) { definition in
                    Button {
                    vm.viewManager.addWidget(definition, at: column)
                } label: {
                    Label(definition.title, systemImage: definition.icon)
                }
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                Text("Add")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyWidgetState: View {
    var vm: NotchViewModel
    var isEditing: Bool

    var body: some View {
        let content = VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.04))
                .frame(width: 54, height: 54)
                .overlay {
                    Image(systemName: isEditing ? "plus.square.on.square" : "square.grid.3x3.middle.filled")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                }

            Text(isEditing ? "Add your first widget" : "This view is empty")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))

            Text(isEditing ? "Click anywhere to add your first widget." : "Enter edit mode to add widgets here.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.42))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)

        if isEditing {
            Menu {
                ForEach(vm.viewManager.widgetDefinitions) { definition in
                    Button {
                        vm.viewManager.addWidget(definition, at: 0)
                    } label: {
                        Label(definition.title, systemImage: definition.icon)
                    }
                }
            } label: {
                content
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct WidgetCard: View {
    var widget: WidgetInstance
    var vm: NotchViewModel
    var isEditing: Bool
    var isHeld: Bool
    var minSpan: Int
    var maxSpan: Int
    var canSetSpan: (Int) -> Bool
    var onSetSpan: (Int) -> Void
    var onRemove: () -> Void
    var onHandleDragChanged: (CGFloat) -> Void
    var onHandleDragEnded: (CGFloat) -> Void

    var body: some View {
        let definition = vm.viewManager.definition(for: widget) ?? .missing(id: widget.widgetID)
        let tint = definition.tint
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: definition.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(definition.caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer(minLength: 0)
            }

            widgetPreview(for: definition, tint: tint)
        }
        .blur(radius: isEditing ? 1.4 : 0)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            cardShape
                .fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHeld ? 0.16 : 0.1),
                            tint.opacity(0.14)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .clipShape(cardShape)
        .overlay(
            cardShape
                .strokeBorder(.white.opacity(isEditing ? 0.26 : 0.08), lineWidth: isEditing ? 1.6 : 1)
        )
        .overlay {
            if isEditing {
                cardShape
                    .fill(.black.opacity(0.08))
                    .contentShape(cardShape)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                onHandleDragChanged(value.translation.width)
                            }
                            .onEnded { value in
                                onHandleDragEnded(value.translation.width)
                            }
                    )
            }
        }
        .overlay(alignment: .center) {
            if isEditing {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if isEditing {
                HStack(spacing: 6) {
                    editControlButton(
                        systemName: "minus",
                        tint: .white,
                        isEnabled: canShrink,
                        action: shrink
                    )

                    editControlButton(
                        systemName: "plus",
                        tint: .white,
                        isEnabled: canGrow,
                        action: grow
                    )

                }
                .padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isEditing {
                editControlButton(
                    systemName: "trash",
                    tint: Color(red: 0.98, green: 0.39, blue: 0.43),
                    isEnabled: true,
                    action: onRemove
                )
                .padding(10)
            }
        }
    }

    private var smallerSpan: Int? {
        let candidate = widget.span - 1
        guard candidate >= minSpan else { return nil }
        return candidate
    }

    private var largerSpan: Int? {
        let candidate = widget.span + 1
        guard candidate <= maxSpan else { return nil }
        return candidate
    }

    private var canShrink: Bool {
        guard let smallerSpan else { return false }
        return canSetSpan(smallerSpan)
    }

    private var canGrow: Bool {
        guard let largerSpan else { return false }
        return canSetSpan(largerSpan)
    }

    private func shrink() {
        guard let smallerSpan, canSetSpan(smallerSpan) else { return }
        onSetSpan(smallerSpan)
    }

    private func grow() {
        guard let largerSpan, canSetSpan(largerSpan) else { return }
        onSetSpan(largerSpan)
    }

    private func editControlButton(
        systemName: String,
        tint: Color,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint.opacity(isEnabled ? 1 : 0.35))
                .frame(width: 26, height: 26)
                .background(.black.opacity(isEnabled ? 0.28 : 0.18), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(tint.opacity(isEnabled ? 0.35 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    @ViewBuilder
    private func widgetPreview(for definition: WidgetDefinition, tint: Color) -> some View {
        RuntimeWidgetSurface(widget: widget, definition: definition, vm: vm, tint: tint)
    }
}

private struct RuntimeWidgetSurface: View {
    var widget: WidgetInstance
    var definition: WidgetDefinition
    var vm: NotchViewModel
    var tint: Color

    var body: some View {
        Group {
            if let error = vm.widgetRuntime.error(for: widget.id) {
                runtimeErrorSurface(message: error)
            } else if let tree = vm.widgetRuntime.renderTree(for: widget.id) {
                RuntimeV2NodeView(node: tree)
            } else {
                runtimeLoadingSurface
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: "\(widget.id.uuidString)-\(widget.span)-\(vm.isEditingLayout)-\(vm.viewManager.selectedViewID.uuidString)") {
            if vm.widgetRuntime.isMounted(instanceID: widget.id) {
                vm.widgetRuntime.update(
                    instanceID: widget.id,
                    viewID: vm.viewManager.selectedViewID,
                    span: widget.span,
                    isEditing: vm.isEditingLayout
                )
            } else {
                vm.widgetRuntime.mount(
                    widget: definition,
                    instanceID: widget.id,
                    viewID: vm.viewManager.selectedViewID,
                    span: widget.span,
                    isEditing: vm.isEditingLayout
                )
            }
        }
    }

    private var runtimeLoadingSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(height: 42)

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(tint.opacity(0.7))
                .frame(width: 80, height: 10)

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 118, height: 8)
        }
    }

    private func runtimeErrorSurface(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 0.98, green: 0.39, blue: 0.43).opacity(0.14))
                .frame(height: 40)
                .overlay(alignment: .leading) {
                    Label(runtimeErrorTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.98, green: 0.58, blue: 0.63))
                        .padding(.horizontal, 12)
                }

            Text(runtimeErrorMessage(detail: message))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var runtimeErrorTitle: String {
        #if DEBUG
        "Runtime Error"
        #else
        "Widget Unavailable"
        #endif
    }

    private func runtimeErrorMessage(detail: String) -> String {
        #if DEBUG
        detail
        #else
        "This widget is currently unavailable. It may have been removed, disabled, or failed to load."
        #endif
    }
}

private struct RuntimeV2NodeView: View {
    var node: RenderNodeV2

    var body: some View {
        switch node.type {
        case "Stack":
            VStack(alignment: .leading, spacing: CGFloat(node.number("spacing") ?? 8)) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    RuntimeV2NodeView(node: child)
                }
            }
        case "Inline":
            HStack(spacing: CGFloat(node.number("spacing") ?? 8)) {
                ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
                    RuntimeV2NodeView(node: child)
                }
            }
        case "Text", "__text":
            Text(node.string("text") ?? "")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .frame(maxWidth: .infinity, alignment: .leading)
        case "Spacer":
            Spacer(minLength: 0)
        default:
            EmptyView()
        }
    }
}

private struct RuntimeNodeView: View {
    var node: RuntimeRenderNode
    var vm: NotchViewModel
    var instanceID: UUID
    var tint: Color

    var body: some View {
        switch node.type {
        case "Stack":
            stackView
        case "Inline":
            inlineView
        case "Row":
            rowView
        case "Text":
            textView
        case "Button":
            buttonView
        case "Icon":
            iconView
        case "IconButton":
            iconButtonView
        case "Checkbox":
            checkboxView
        case "Input":
            RuntimeInputNodeView(node: node, vm: vm, instanceID: instanceID, tint: tint)
        case "Spacer":
            Spacer(minLength: 0)
        default:
            EmptyView()
        }
    }

    private var textView: some View {
        Text(node.text ?? "")
            .font(textFont(role: node.role))
            .foregroundStyle(textColor(tone: node.tone, role: node.role))
            .multilineTextAlignment(.leading)
            .lineLimit(node.lineClamp)
            .strikethrough(node.strikethrough ?? false, color: .white.opacity(0.28))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttonView: some View {
        Button {
            if let action = node.action {
                vm.widgetRuntime.triggerAction(action, payload: node.payload, for: instanceID)
            }
        } label: {
            Text(node.title ?? "Action")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(tint.opacity(0.24))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.32), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var iconView: some View {
        Image(systemName: node.symbol ?? "questionmark")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(iconColor(tone: node.tone))
    }

    private var iconButtonView: some View {
        Button {
            guard let action = node.action, !(node.disabled ?? false) else { return }
            vm.widgetRuntime.triggerAction(action, payload: node.payload, for: instanceID)
        } label: {
            Image(systemName: node.symbol ?? "questionmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(iconColor(tone: node.tone))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .disabled(node.disabled ?? false)
    }

    private var checkboxView: some View {
        Button {
            guard let action = node.action else { return }
            vm.widgetRuntime.triggerAction(action, payload: node.payload, for: instanceID)
        } label: {
            Circle()
                .strokeBorder(.white.opacity((node.checked ?? false) ? 0.12 : 0.28), lineWidth: 1.2)
                .frame(width: 14, height: 14)
                .overlay {
                    if node.checked ?? false {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stackView: some View {
        let spacing = node.spacing.map { CGFloat($0) } ?? 8
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(node.children) { child in
                RuntimeNodeView(node: child, vm: vm, instanceID: instanceID, tint: tint)
            }
        }
    }

    @ViewBuilder
    private var inlineView: some View {
        let spacing = node.spacing.map { CGFloat($0) } ?? 8
        HStack(spacing: spacing) {
            ForEach(node.children) { child in
                if child.type == "Spacer" {
                    Spacer(minLength: 0)
                } else {
                    RuntimeNodeView(node: child, vm: vm, instanceID: instanceID, tint: tint)
                }
            }
        }
    }

    private var rowView: some View {
        Button {
            guard let action = node.action else { return }
            vm.widgetRuntime.triggerAction(action, payload: node.payload, for: instanceID)
        } label: {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .overlay {
                    if node.children.count == 1 {
                        RuntimeNodeView(node: node.children[0], vm: vm, instanceID: instanceID, tint: tint)
                            .padding(.horizontal, 10)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(node.children) { child in
                                RuntimeNodeView(node: child, vm: vm, instanceID: instanceID, tint: tint)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(node.action == nil)
    }

    private func textFont(role: String?) -> Font {
        switch role {
        case "caption":
            .system(size: 11, weight: .semibold)
        case "placeholder":
            .system(size: 11, weight: .medium)
        default:
            .system(size: 11, weight: .medium)
        }
    }

    private func textColor(tone: String?, role: String?) -> Color {
        if role == "placeholder" {
            return .white.opacity(0.48)
        }

        switch tone {
        case "primary":
            return Color.white.opacity(0.84)
        case "secondary":
            return Color.white.opacity(0.72)
        case "tertiary":
            return Color.white.opacity(0.42)
        default:
            return Color.white.opacity(0.72)
        }
    }

    private func iconColor(tone: String?) -> Color {
        switch tone {
        case "primary":
            return .white.opacity(0.84)
        case "tertiary":
            return .white.opacity(0.26)
        default:
            return .white.opacity(0.42)
        }
    }
}

private struct RuntimeInputNodeView: View {
    var node: RuntimeRenderNode
    var vm: NotchViewModel
    var instanceID: UUID
    var tint: Color

    @State private var text = ""

    var body: some View {
        HStack(spacing: 4) {
            if let leadingAccessory = node.leadingAccessory {
                RuntimeNodeView(node: leadingAccessory.node, vm: vm, instanceID: instanceID, tint: tint)
            }

            RuntimeInputTextField(
                text: $text,
                placeholder: node.placeholder ?? "",
                onCommit: {
                    guard let action = node.submitAction else { return }
                    vm.widgetRuntime.triggerAction(
                        action,
                        payload: RuntimeActionPayload(value: text, id: nil),
                        for: instanceID
                    )
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            if let trailingAccessory = node.trailingAccessory {
                Circle()
                    .fill(.white.opacity(0.08))
                    .frame(width: 24, height: 24)
                    .overlay {
                        RuntimeNodeView(node: trailingAccessory.node, vm: vm, instanceID: instanceID, tint: tint)
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.07))
        )
        .onAppear {
            text = node.value ?? ""
        }
        .onChange(of: node.value ?? "") { _, newValue in
            if newValue != text {
                text = newValue
            }
        }
        .onChange(of: text) { oldValue, newValue in
            guard oldValue != newValue,
                  newValue != (node.value ?? ""),
                  let action = node.changeAction else { return }

            vm.widgetRuntime.triggerAction(
                action,
                payload: RuntimeActionPayload(value: newValue, id: nil),
                for: instanceID
            )
        }
    }
}

private struct RuntimeInputTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = RuntimeFocusableTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.stringValue = text
        configureNotchTextField(
            textField,
            placeholder: placeholder,
            font: .systemFont(ofSize: 11, weight: .medium),
            textColor: .white.withAlphaComponent(0.72)
        )
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.onCommit = onCommit

        if textField.stringValue != text {
            textField.stringValue = text
        }
    }

    static func dismantleNSView(_ textField: NSTextField, coordinator: Coordinator) {
        if let panel = textField.window as? NotchPanel {
            panel.releaseKeyInput()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onCommit: () -> Void

        init(text: Binding<String>, onCommit: @escaping () -> Void) {
            _text = text
            self.onCommit = onCommit
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField else { return }
            text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let window = textField.window else { return }

            if let panel = window as? NotchPanel {
                panel.activateForKeyInput()
            }

            if let editor = window.fieldEditor(true, for: textField) as? NSTextView {
                editor.insertionPointColor = .white
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let textField = obj.object as? NSTextField,
                  let panel = textField.window as? NotchPanel else { return }

            panel.releaseKeyInput()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onCommit()
                return true
            }

            return false
        }
    }
}

private final class RuntimeFocusableTextField: NSTextField {
    override func mouseDown(with event: NSEvent) {
        if let panel = window as? NotchPanel {
            panel.activateForKeyInput()
        }

        super.mouseDown(with: event)
    }
}

private struct HeaderAccessoryButton: View {
    var activeSymbol: String
    var inactiveSymbol: String?
    var activeLabel: String?
    var inactiveLabel: String?
    var tint: Color = .white
    var isActive = false
    var activeRotation: Angle = .zero
    var inactiveRotation: Angle = .zero
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let label = isActive ? activeLabel : inactiveLabel {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle((isActive ? tint : .white).opacity(isActive ? 0.95 : 0.72))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isActive ? tint.opacity(0.18) : .white.opacity(0.06))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isActive ? tint.opacity(0.4) : .white.opacity(0.06),
                                    lineWidth: 1
                                )
                        )
                } else {
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
            }
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
                panel.activateForKeyInput()
                DispatchQueue.main.async {
                    panel.activateForKeyInput()
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
                panel.releaseKeyInput()
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

struct EditModeConfirmationDialog: View {
    var vm: NotchViewModel
    @State private var escMonitor: Any?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture {
                    cancel()
                }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Save layout changes?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))

                    Text("Your edits will be lost if you revert this session.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }

                HStack(spacing: 8) {
                    Button(action: discard) {
                        Text("Discard")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.98, green: 0.39, blue: 0.43))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(red: 0.98, green: 0.39, blue: 0.43).opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color(red: 0.98, green: 0.39, blue: 0.43).opacity(0.3), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: save) {
                        Text("Save")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(red: 0.39, green: 0.68, blue: 0.98).opacity(0.2))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color(red: 0.39, green: 0.68, blue: 0.98).opacity(0.34), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 6) {
                    KeycapLabel("esc")
                    Text("keep editing")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))

                    Spacer(minLength: 0)

                    KeycapLabel("return")
                    Text("save")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .frame(width: 320)
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
            if let panel = NotchPanel.contentPanel {
                panel.activateForKeyInput()
                DispatchQueue.main.async {
                    panel.activateForKeyInput()
                }
            }
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 {
                    cancel()
                    return nil
                }
                if event.keyCode == 36 {
                    save()
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
            if let panel = NotchPanel.contentPanel {
                panel.releaseKeyInput()
            }
        }
    }

    private func save() {
        vm.saveEditMode()
    }

    private func discard() {
        vm.revertEditMode()
    }

    private func cancel() {
        vm.dismissEditConfirmation()
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
        configureNotchTextField(
            textField,
            placeholder: placeholder,
            font: .systemFont(ofSize: 12, weight: .medium),
            textColor: .white
        )
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

private func configureNotchTextField(
    _ textField: NSTextField,
    placeholder: String,
    font: NSFont,
    textColor: NSColor
) {
    textField.placeholderString = placeholder
    textField.isBordered = false
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.isEditable = true
    textField.isSelectable = true
    textField.isEnabled = true
    textField.font = font
    textField.textColor = textColor
    textField.cell?.usesSingleLineMode = true
    textField.cell?.lineBreakMode = .byTruncatingTail
}

struct NotchBlurView: View {
    var vm: NotchViewModel

    var body: some View {
        EmptyView()
    }
}
