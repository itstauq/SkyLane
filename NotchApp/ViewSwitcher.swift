import AppKit
import SwiftUI

struct ViewSwitcher: View {
    var viewManager: ViewManager
    var vm: NotchViewModel

    @State private var heldViewID: UUID?
    @State private var gestureBaselineTranslation: CGFloat = 0
    @State private var visualDragOffset: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]

    private let tabSpacing: CGFloat = 4
    private let tabHeight: CGFloat = 28
    private let tabMinWidth: CGFloat = 28
    private let tabMaxWidth: CGFloat = 140
    private let plusButtonWidth: CGFloat = 28
    private let horizontalInset: CGFloat = 4
    private let controlGap: CGFloat = 4
    private let reorderThresholdFactor: CGFloat = 0.82

    var body: some View {
        GeometryReader { proxy in
            let tabsMaxWidth = max(proxy.size.width - plusButtonWidth - controlGap, 0)
            let layout = tabLayout(for: tabsMaxWidth)

            Group {
                if layout.needsScroll {
                    HStack(spacing: controlGap) {
                        ScrollViewReader { scrollProxy in
                            ScrollView(.horizontal, showsIndicators: false) {
                                tabStripRow(layout: layout)
                                    .frame(width: max(layout.contentWidth, tabsMaxWidth), alignment: .leading)
                            }
                            .onAppear {
                                scrollToSelected(using: scrollProxy, animated: false)
                            }
                            .onChange(of: viewManager.selectedViewID) { _, _ in
                                scrollToSelected(using: scrollProxy, animated: true)
                            }
                        }
                        .frame(width: tabsMaxWidth, alignment: .leading)
                        .clipped()

                        addButton
                            .frame(width: plusButtonWidth, height: tabHeight)
                    }
                    .background(.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(width: proxy.size.width, alignment: .leading)
                } else {
                    HStack(spacing: controlGap) {
                        tabStripRow(layout: layout)
                            .frame(width: min(layout.contentWidth, tabsMaxWidth), alignment: .leading)
                            .clipped()
                        addButton
                            .frame(width: plusButtonWidth, height: tabHeight)
                    }
                    .background(.white.opacity(0.08), in: Capsule())
                    .foregroundStyle(.white)
                    .frame(width: min(layout.contentWidth + controlGap + plusButtonWidth, proxy.size.width), alignment: .leading)
                }
            }
        }
        .frame(height: 36)
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { _ in
            vm.isViewMenuOpen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            vm.isViewMenuOpen = false
        }
    }

    private func tabStripRow(layout: TabLayout) -> some View {
        HStack(spacing: tabSpacing) {
            ForEach(viewManager.views) { view in
                let tabWidth = layout.width(for: view.id)
                let isSelected = view.id == viewManager.selectedViewID
                let isHeld = heldViewID == view.id
                let showsTitle = showsTitle(for: tabWidth, isSelected: isSelected)

                Button {
                    guard heldViewID == nil else { return }
                    viewManager.select(view)
                } label: {
                    tabView(for: view, showsTitle: showsTitle, isSelected: isSelected, isHeld: isHeld)
                }
                .buttonStyle(.plain)
                .frame(width: tabWidth)
                .offset(x: displayedOffset(for: view.id, isHeld: isHeld))
                .scaleEffect(isHeld ? 1.03 : 1)
                .opacity(isHeld ? 0.92 : 1)
                .shadow(color: .black.opacity(isHeld ? 0.28 : 0), radius: isHeld ? 10 : 0, y: isHeld ? 6 : 0)
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(isHeld ? 0.2 : 0), lineWidth: 1)
                )
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: TabFramePreferenceKey.self,
                                value: [view.id: geometry.frame(in: .named("TabStripArea"))]
                            )
                    }
                )
                .zIndex(isHeld ? 2 : 0)
                .contentShape(Rectangle())
                .contextMenu {
                    contextMenu(for: view)
                }
                .simultaneousGesture(armReorderGesture(for: view.id))
                .simultaneousGesture(slideReorderGesture(for: view.id))
            }
        }
        .coordinateSpace(name: "TabStripArea")
        .padding(.horizontal, horizontalInset)
        .padding(.vertical, 4)
        .onPreferenceChange(TabFramePreferenceKey.self) { frames in
            tabFrames = frames
        }
        .animation(.interpolatingSpring(duration: 0.24, bounce: 0.18), value: viewManager.views)
        .animation(.interpolatingSpring(duration: 0.18, bounce: 0.12), value: heldViewID)
        .animation(.interpolatingSpring(duration: 0.14, bounce: 0.08), value: visualDragOffset)
    }

    private func tabView(for view: SavedView, showsTitle: Bool, isSelected: Bool, isHeld: Bool) -> some View {
        HStack(spacing: showsTitle ? 6 : 0) {
            Image(systemName: view.icon)
                .font(.system(size: 10, weight: .semibold))

            if showsTitle {
                Text(view.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, showsTitle ? 10 : 0)
        .frame(height: tabHeight)
        .background(
            Capsule()
                .fill(isHeld ? .white.opacity(0.18) : (isSelected ? .white.opacity(0.12) : .clear))
        )
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(isHeld ? 0.16 : (isSelected ? 0.1 : 0.04)), lineWidth: 1)
        )
        .foregroundStyle(isSelected || isHeld ? .white : .white.opacity(0.68))
        .contentShape(Capsule())
    }

    private func armReorderGesture(for viewID: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.18)
            .onEnded { _ in
                if let view = currentView(for: viewID) {
                    viewManager.select(view)
                }
                heldViewID = viewID
                gestureBaselineTranslation = 0
                visualDragOffset = 0
            }
    }

    private func slideReorderGesture(for viewID: UUID) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("TabStripArea"))
            .onChanged { value in
                guard heldViewID == viewID else { return }
                handleReorderDrag(for: viewID, translation: value.translation.width)
            }
            .onEnded { _ in
                guard heldViewID == viewID else { return }
                endReorderGesture()
            }
    }

    private func handleReorderDrag(for viewID: UUID, translation: CGFloat) {
        let delta = translation - gestureBaselineTranslation
        visualDragOffset = draggedDisplayOffset(for: delta)

        let rightThreshold = moveThreshold(for: viewID, direction: .right)
        let leftThreshold = moveThreshold(for: viewID, direction: .left)

        if delta > rightThreshold,
           let view = currentView(for: viewID),
           viewManager.canMoveViewRight(view) {
            let swapDistance = neighborCenterDistance(for: viewID, direction: .right)
            withAnimation(.snappy(duration: 0.16)) {
                viewManager.moveViewRight(view)
            }
            gestureBaselineTranslation += swapDistance
            visualDragOffset = draggedDisplayOffset(for: translation - gestureBaselineTranslation)
        } else if delta < -leftThreshold,
                  let view = currentView(for: viewID),
                  viewManager.canMoveViewLeft(view) {
            let swapDistance = neighborCenterDistance(for: viewID, direction: .left)
            withAnimation(.snappy(duration: 0.16)) {
                viewManager.moveViewLeft(view)
            }
            gestureBaselineTranslation -= swapDistance
            visualDragOffset = draggedDisplayOffset(for: translation - gestureBaselineTranslation)
        }
    }

    private func endReorderGesture() {
        withAnimation(.interpolatingSpring(duration: 0.22, bounce: 0.18)) {
            heldViewID = nil
            visualDragOffset = 0
        }
        gestureBaselineTranslation = 0
    }

    private func moveThreshold(for viewID: UUID, direction: MoveDirection) -> CGFloat {
        neighborCenterDistance(for: viewID, direction: direction) * reorderThresholdFactor
    }

    private func neighborCenterDistance(for viewID: UUID, direction: MoveDirection) -> CGFloat {
        guard let index = viewManager.views.firstIndex(where: { $0.id == viewID }) else {
            return 32
        }

        let neighborIndex = direction == .left ? index - 1 : index + 1
        guard viewManager.views.indices.contains(neighborIndex) else {
            return 32
        }

        let currentWidth = tabFrames[viewID]?.width ?? 72
        let neighborID = viewManager.views[neighborIndex].id
        let neighborWidth = tabFrames[neighborID]?.width ?? 72

        return max(24, ((currentWidth + neighborWidth) / 2) + (tabSpacing / 2))
    }

    private func currentView(for id: UUID) -> SavedView? {
        viewManager.views.first(where: { $0.id == id })
    }

    private func displayedOffset(for viewID: UUID, isHeld: Bool) -> CGFloat {
        if isHeld {
            return visualDragOffset
        }

        return previewOffset(for: viewID)
    }

    private func previewOffset(for viewID: UUID) -> CGFloat {
        guard let heldViewID,
              let heldIndex = viewManager.views.firstIndex(where: { $0.id == heldViewID }),
              visualDragOffset != 0 else { return 0 }

        let direction: MoveDirection = visualDragOffset > 0 ? .right : .left
        let neighborIndex = direction == .right ? heldIndex + 1 : heldIndex - 1

        guard viewManager.views.indices.contains(neighborIndex) else { return 0 }

        let neighborID = viewManager.views[neighborIndex].id
        guard neighborID == viewID else { return 0 }

        let threshold = max(moveThreshold(for: heldViewID, direction: direction), 1)
        let progress = min(abs(visualDragOffset) / threshold, 1)
        let easedProgress = progress * progress * (3 - (2 * progress))
        let neighborWidth = tabFrames[neighborID]?.width ?? 72
        let previewDistance = min(22, (neighborWidth * 0.2) + 6)

        return direction == .right ? -(previewDistance * easedProgress) : (previewDistance * easedProgress)
    }

    private func draggedDisplayOffset(for delta: CGFloat) -> CGFloat {
        let magnitude = abs(delta)
        let resistedMagnitude: CGFloat

        if magnitude <= 48 {
            resistedMagnitude = magnitude * 0.78
        } else {
            resistedMagnitude = (48 * 0.78) + ((magnitude - 48) * 0.22)
        }

        return min(resistedMagnitude, 58) * (delta >= 0 ? 1 : -1)
    }

    private var addButton: some View {
        Button {
            viewManager.addView(name: "New View")
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .frame(width: plusButtonWidth, height: tabHeight)
                .background(.white.opacity(0.06), in: Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func contextMenu(for view: SavedView) -> some View {
        Button {
            viewManager.select(view)
        } label: {
            Label("Show \"\(view.name)\"", systemImage: "arrow.turn.down.right")
        }

        Divider()

        Button {
            vm.renameViewName = view.name
            viewManager.select(view)
            vm.isRenamingView = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            viewManager.moveViewLeft(view)
        } label: {
            Label("Move Left", systemImage: "arrow.left")
        }
        .disabled(!viewManager.canMoveViewLeft(view))

        Button {
            viewManager.moveViewRight(view)
        } label: {
            Label("Move Right", systemImage: "arrow.right")
        }
        .disabled(!viewManager.canMoveViewRight(view))

        Menu {
            ForEach(ViewManager.availableIcons, id: \.self) { icon in
                Button {
                    viewManager.setIcon(view, to: icon)
                } label: {
                    HStack {
                        Image(systemName: icon)
                        Text(icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ").capitalized)
                        if icon == view.icon {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            Label("Icon", systemImage: "paintpalette")
        }

        if viewManager.views.count > 1 {
            Divider()

            Button(role: .destructive) {
                viewManager.removeView(view)
            } label: {
                Label("Delete \"\(view.name)\"", systemImage: "trash")
            }
        }
    }

    private func tabLayout(for availableWidth: CGFloat) -> TabLayout {
        let views = viewManager.views
        let reservedWidth = horizontalInset * 2
        let totalSpacing = CGFloat(max(views.count - 1, 0)) * tabSpacing
        let availableTabWidth = max(availableWidth - reservedWidth - totalSpacing, 0)
        let visibleTabCap = availableTabWidth / 3

        let preferredWidths = views.map { min(preferredWidth(for: $0), visibleTabCap) }
        let minimumWidths = Array(repeating: tabMinWidth, count: views.count)
        let preferredTotal = preferredWidths.reduce(0, +)
        let selectedIndex = views.firstIndex { $0.id == viewManager.selectedViewID }
        let minimumTotalKeepingSelectedPreferred = minimumWidths.enumerated().reduce(CGFloat(0)) { partial, element in
            let (index, minimumWidth) = element
            if index == selectedIndex {
                return partial + preferredWidths[index]
            }
            return partial + minimumWidth
        }

        let widths: [CGFloat]
        let needsScroll: Bool

        if preferredTotal <= availableTabWidth {
            widths = preferredWidths
            needsScroll = false
        } else if minimumTotalKeepingSelectedPreferred <= availableTabWidth {
            widths = compressedWidths(
                preferred: preferredWidths,
                minimum: minimumWidths,
                targetTotal: availableTabWidth
            )
            needsScroll = false
        } else {
            widths = minimumWidths.enumerated().map { index, minimumWidth in
                if index == selectedIndex {
                    return preferredWidths[index]
                }
                return minimumWidth
            }
            needsScroll = true
        }

        let widthMap = Dictionary(uniqueKeysWithValues: zip(views.map(\.id), widths))
        let contentWidth = widths.reduce(0, +) + reservedWidth + totalSpacing

        return TabLayout(
            widthsByID: widthMap,
            contentWidth: contentWidth,
            needsScroll: needsScroll
        )
    }

    private func preferredWidth(for view: SavedView) -> CGFloat {
        let measuredTitleWidth = view.name.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width
        let preferredWidth = measuredTitleWidth + 44
        return min(preferredWidth, tabMaxWidth)
    }

    private func compressedWidths(preferred: [CGFloat], minimum: [CGFloat], targetTotal: CGFloat) -> [CGFloat] {
        var widths = preferred
        let overflow = preferred.reduce(0, +) - targetTotal

        let selectedIndex = viewManager.views.firstIndex { $0.id == viewManager.selectedViewID }
        let nonSelectedIndices = widths.indices.filter { $0 != selectedIndex }

        _ = shrink(widths: &widths, minimum: minimum, indices: nonSelectedIndices, overflow: overflow)

        return widths
    }

    private func shrink(widths: inout [CGFloat], minimum: [CGFloat], indices: [Int], overflow: CGFloat) -> CGFloat {
        var remainingOverflow = overflow
        var flexibleIndices = indices.filter { widths[$0] - minimum[$0] > 0.5 }

        while remainingOverflow > 0.5, !flexibleIndices.isEmpty {
            let share = remainingOverflow / CGFloat(flexibleIndices.count)
            var nextFlexibleIndices: [Int] = []

            for index in flexibleIndices {
                let shrinkAmount = min(widths[index] - minimum[index], share)
                widths[index] -= shrinkAmount
                remainingOverflow -= shrinkAmount

                if widths[index] - minimum[index] > 0.5 {
                    nextFlexibleIndices.append(index)
                }
            }

            flexibleIndices = nextFlexibleIndices
        }

        return remainingOverflow
    }

    private func showsTitle(for width: CGFloat, isSelected: Bool) -> Bool {
        isSelected || width > 68
    }

    private func scrollToSelected(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedView = viewManager.selectedView else { return }

        let action = {
            proxy.scrollTo(selectedView.id, anchor: .center)
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.snappy(duration: 0.22)) {
                    action()
                }
            } else {
                action()
            }
        }
    }
}

private struct TabLayout {
    var widthsByID: [UUID: CGFloat]
    var contentWidth: CGFloat
    var needsScroll: Bool

    func width(for id: UUID) -> CGFloat {
        widthsByID[id] ?? 28
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum MoveDirection {
    case left
    case right
}
