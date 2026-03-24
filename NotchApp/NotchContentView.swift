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
                            vm.toggleEditMode()
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
                if vm.isEditingLayout, remainingColumns > 0 {
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

                        WidgetCard(
                            widget: widget,
                            vm: vm,
                            isEditing: vm.isEditingLayout,
                            isHeld: isHeld,
                            availableSpans: vm.viewManager.availableSpans(for: widget.id),
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
            ForEach(WidgetKind.allCases) { kind in
                Button {
                    vm.viewManager.addWidget(kind, at: column)
                } label: {
                    Label(kind.title, systemImage: kind.icon)
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

private struct WidgetCard: View {
    var widget: WidgetInstance
    var vm: NotchViewModel
    var isEditing: Bool
    var isHeld: Bool
    var availableSpans: [Int]
    var canSetSpan: (Int) -> Bool
    var onSetSpan: (Int) -> Void
    var onRemove: () -> Void
    var onHandleDragChanged: (CGFloat) -> Void
    var onHandleDragEnded: (CGFloat) -> Void

    var body: some View {
        let tint = widget.kind.tint
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: widget.kind.icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(widget.kind.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(widget.kind.caption)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                }

                Spacer(minLength: 0)

                if widget.kind == .notes {
                    Circle()
                        .fill(.white.opacity(0.06))
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.72))
                        }
                }
            }

            widgetPreview(for: widget.kind, tint: tint)
        }
        .blur(radius: isEditing ? 1.4 : 0)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
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
        .overlay(alignment: .topTrailing) {
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

                    editControlButton(
                        systemName: "trash",
                        tint: Color(red: 0.98, green: 0.39, blue: 0.43),
                        isEnabled: true,
                        action: onRemove
                    )
                }
                .padding(10)
            }
        }
    }

    private var sortedSpans: [Int] {
        availableSpans.sorted()
    }

    private var smallerSpan: Int? {
        sortedSpans.last(where: { $0 < widget.span })
    }

    private var largerSpan: Int? {
        sortedSpans.first(where: { $0 > widget.span })
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
    private func widgetPreview(for kind: WidgetKind, tint: Color) -> some View {
        switch kind {
        case .inbox:
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.07))
                    .frame(height: 40)
                    .overlay {
                        HStack(spacing: 4) {
                            Text("Press ↵ to capture another item")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Circle()
                                .fill(.white.opacity(0.08))
                                .frame(width: 24, height: 24)
                                .overlay {
                                    Image(systemName: "mic")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.72))
                                }
                        }
                        .padding(.horizontal, 8)
                    }

                captureItemRow(
                    title: "Potential whitespace bug in tab rename field",
                    isChecked: false
                )

                captureItemRow(
                    title: "Pick up oat milk on the way home",
                    isChecked: true
                )
            }
        case .pomodoro:
            VStack(spacing: 20) {
                HStack(spacing: 8) {
                    Text("Cycle 2 of 4")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))

                    HStack(spacing: 4) {
                        ForEach(0..<4, id: \.self) { index in
                            Circle()
                                .fill(index < 2 ? tint : .white.opacity(0.12))
                                .frame(width: 6, height: 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                Text("25:00")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                    .frame(maxWidth: .infinity)

                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(tint)
                        .frame(width: 68, height: 34)
                        .overlay {
                            Text("Start")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.black.opacity(0.76))
                        }

                    pomodoroActionButton("arrow.counterclockwise")
                    pomodoroActionButton("gearshape.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        case .calendar:
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        scheduleRow(time: "9:00", meridiem: "AM", color: Color(red: 0.28, green: 0.58, blue: 0.98), title: "Morning Standup", meta: "Zoom · Engineering")
                        Divider().background(.white.opacity(0.08))
                        scheduleRow(time: "10:30", meridiem: "AM", color: Color(red: 0.72, green: 0.36, blue: 0.98), title: "Design Review", meta: "Figma · Product")
                        Divider().background(.white.opacity(0.08))
                        scheduleRow(time: "1:00", meridiem: "PM", color: Color(red: 0.2, green: 0.82, blue: 0.46), title: "1:1 with Sarah", meta: "Office · Mgmt")
                        Divider().background(.white.opacity(0.08))
                        scheduleRow(time: "3:30", meridiem: "PM", color: Color(red: 0.99, green: 0.48, blue: 0.18), title: "Sprint Planning", meta: "Slack Huddle · Team")
                    }
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        case .cameraPreview:
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay {
                    ZStack {
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.28, blue: 0.34),
                                Color(red: 0.18, green: 0.2, blue: 0.26),
                                Color(red: 0.12, green: 0.14, blue: 0.19)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )

                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.14),
                                Color.white.opacity(0.03),
                                .clear
                            ],
                            center: .topTrailing,
                            startRadius: 12,
                            endRadius: 180
                        )

                        LinearGradient(
                            colors: [
                                tint.opacity(0.2),
                                .clear,
                                Color.black.opacity(0.22)
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .overlay(alignment: .topTrailing) {
                    cameraOverlayBadge("gearshape.fill")
                        .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    cameraOverlayBadge("photo.badge.plus")
                        .padding(12)
                }
                .overlay(alignment: .bottomLeading) {
                    cameraOverlayBadge("waveform")
                        .padding(12)
                }
        case .ambientSounds:
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ambientSoundTile(title: "Rain", icon: "cloud.rain.fill", step: 4, selected: true, tint: tint)
                    ambientSoundTile(title: "Fire", icon: "flame.fill", step: 1, selected: false, tint: tint)
                    ambientSoundTile(title: "Waves", icon: "water.waves", step: 1, selected: false, tint: tint)
                }

                HStack(spacing: 8) {
                    ambientSoundTile(title: "Forest", icon: "leaf.fill", step: 1, selected: false, tint: tint)
                    ambientSoundTile(title: "Cafe", icon: "cup.and.saucer.fill", step: 3, selected: true, tint: tint)
                    ambientSoundTile(title: "Lo-fi", icon: "music.note.list", step: 2, selected: true, tint: tint)
                }
            }
        case .music:
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.opacity(0.18))
                    .frame(height: 94)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(tint)
                            Text("After Hours")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.88))
                        }
                    }

                HStack(spacing: 12) {
                    ForEach(["backward.fill", "play.fill", "forward.fill"], id: \.self) { symbol in
                        Circle()
                            .fill(symbol == "play.fill" ? tint : .white.opacity(0.08))
                            .frame(width: symbol == "play.fill" ? 36 : 28, height: symbol == "play.fill" ? 36 : 28)
                            .overlay {
                                Image(systemName: symbol)
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(symbol == "play.fill" ? .black.opacity(0.75) : .white.opacity(0.72))
                            }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        case .notes:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    noteCard("Repair shop address: 512 W 48th St, New York...", time: "16:46", tint: tint)
                    noteCard("Need to confirm invite flow before shipping onboarding polish.", time: "14:18", tint: tint)
                    noteCard("Try a calmer hover treatment on the tab strip glass.", time: "09:32", tint: tint)
                }
                .padding(.bottom, 18)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .mask(alignment: .bottom) {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.82),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        case .linear:
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        issueRow(id: "LIN-142", title: "Refine widget host row", status: "In Progress", priority: 3)
                        issueRow(id: "LIN-151", title: "Add edit mode affordances", status: "To Do", priority: 2)
                        issueRow(id: "LIN-159", title: "Ship preview gallery", status: "Done", priority: 1)
                        issueRow(id: "LIN-164", title: "Fix tab-strip overflow edge case", status: "To Do", priority: 2)
                        issueRow(id: "LIN-171", title: "Polish capture empty state", status: "In Progress", priority: 3)
                        issueRow(id: "LIN-176", title: "Audit widget height constraints", status: "Done", priority: 1)
                    }
                    .padding(.bottom, 28)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.74),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
        case .gmail:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("5 unread")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        mailRow(sender: "Design", subject: "Review notes", avatar: "D", tint: Color(red: 0.99, green: 0.68, blue: 0.35))
                        mailRow(sender: "Linear", subject: "3 issues assigned", avatar: "L", tint: Color(red: 0.72, green: 0.58, blue: 0.98))
                        mailRow(sender: "Figma", subject: "Updated prototype ready", avatar: "F", tint: Color(red: 0.39, green: 0.68, blue: 0.98))
                    }
                    .padding(.bottom, 18)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .mask(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.82),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func issueRow(id: String, title: String, status: String, priority: Int) -> some View {
            HStack(alignment: .center, spacing: 8) {
            priorityBars(level: priority)

            Text(id)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.42))

            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text(status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.76))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func priorityBars(level: Int) -> some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(index < level ? .white.opacity(0.78) : .white.opacity(0.18))
                    .frame(width: 4, height: CGFloat(8 + (index * 4)))
            }
        }
        .frame(width: 18, alignment: .leading)
    }

    private func scheduleRow(time: String, meridiem: String, color: Color, title: String, meta: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(time)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text(meridiem)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.34))
            }
            .frame(width: 38, alignment: .trailing)

            RoundedRectangle(cornerRadius: 999, style: .continuous)
                .fill(color)
                .frame(width: 4, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(meta)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }

    private func mailRow(sender: String, subject: String, avatar: String, tint: Color) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(tint.opacity(0.18))
                .frame(width: 28, height: 28)
                .overlay {
                    Text(avatar)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(tint)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(sender)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.86))
                    Spacer(minLength: 0)
                    Circle()
                        .fill(Color.red.opacity(0.92))
                        .frame(width: 6, height: 6)
                }

                Text(subject)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.54))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func noteCard(_ text: String, time: String, tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(tint.opacity(0.08))
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)

                    Text(time)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                }
                .padding(12)
            }
            .frame(height: 104)
    }

    private func captureItemRow(title: String, isChecked: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.05))
            .frame(height: 34)
            .overlay {
                HStack(spacing: 8) {
                    Circle()
                        .strokeBorder(.white.opacity(isChecked ? 0.12 : 0.28), lineWidth: 1.2)
                        .frame(width: 14, height: 14)
                        .overlay {
                            if isChecked {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                        }

                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(isChecked ? 0.42 : 0.72))
                        .strikethrough(isChecked, color: .white.opacity(0.28))
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(isChecked ? 0.26 : 0.42))
                }
                .padding(.horizontal, 10)
            }
    }

    private func pomodoroModeChip(_ title: String, selected: Bool, tint: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(selected ? .black.opacity(0.78) : .white.opacity(0.76))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? Color.white.opacity(0.92) : .white.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(selected ? .clear : .white.opacity(0.12), lineWidth: 1)
            )
    }

    private func pomodoroActionButton(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 999, style: .continuous)
            .fill(.white.opacity(0.06))
            .frame(width: 34, height: 34)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
            }
    }

    private func cameraOverlayBadge(_ symbol: String) -> some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.black.opacity(0.28))
            .frame(width: 28, height: 24)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.82))
            }
    }

    private func ambientSoundTile(title: String, icon: String, step: Int, selected: Bool, tint: Color) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? tint : .white.opacity(0.56))

            Text(title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 0.88 : 0.56))
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(index < step ? (selected ? tint : .white.opacity(0.32)) : .white.opacity(0.08))
                        .frame(width: 8, height: 3 + (CGFloat(index) * 2.5))
                }
            }
            .frame(height: 10)
        }
        .frame(maxWidth: .infinity, minHeight: 56)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? tint.opacity(0.14) : .white.opacity(0.04))
        )
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
                panel.needsKeyInput = true
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async {
                    panel.makeKeyAndOrderFront(nil)
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
                panel.needsKeyInput = false
            }
        }
    }

    private func save() {
        vm.saveEditMode()
    }

    private func revert() {
        vm.revertEditMode()
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
