//
//  LayoutPlanner.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation

/// Pure planning module for MenuBarAgent's anchor-constrained physical order.
/// It contains no AX enumeration or synthetic input; callers provide one live
/// snapshot and execute the returned move through the move engine.
enum LayoutPlanner {
    typealias MoveDestination = MenuBarItemManager.MoveDestination
    typealias ControlItemPair = MenuBarItemManager.ControlItemPair

    /// Whether an item can participate in physical ordering for a section on
    /// macOS 27. Apple-hosted items such as Sound and Spotlight cannot be
    /// concealed by the assessment-mode assertion. If they remain assigned to
    /// a concealed section, treating them as orderable creates an impossible
    /// move across Thaw's section divider and an endless retry loop.
    static func isEligibleForSectionOrder(
        _ item: MenuBarItem,
        section: MenuBarSection.Name
    ) -> Bool {
        guard !item.isSystemClone, !item.isControlItem else { return false }
        return section == .visible || !item.isNonConcealableSystemItem
    }

    static func liveOrderSatisfiesDestination(
        items: [MenuBarItem],
        item: MenuBarItem,
        destination: MoveDestination,
        experimentalSystemItemHiding: Bool = false
    ) -> Bool {
        let orderedItems = items
            .filter { !$0.isSystemClone }
            .filter { $0.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding) }
            .sorted(by: visualOrder)
        let target = destination.targetItem
        guard !item.tag.matchesIgnoringWindowID(target.tag),
              let itemIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) }),
              let targetIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(target.tag) })
        else {
            return false
        }

        return switch destination {
        case .leftOfItem: itemIndex + 1 == targetIndex
        case .rightOfItem: itemIndex == targetIndex + 1
        }
    }

    /// Projects a desired order onto independently movable, anchor-bounded
    /// segments. Items never move through a fixed system anchor.
    static func achievableOrderSegments(
        items: [MenuBarItem],
        desiredOrder: [String],
        experimentalSystemItemHiding: Bool = false
    ) -> [[MenuBarItem]] {
        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        let desiredRank = Dictionary(
            desiredOrder.enumerated().map { ($1, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var physicalSegments = [[MenuBarItem]]()
        var currentSegment = [MenuBarItem]()
        for item in orderedItems {
            if item.tag.isLayoutAnchoredSystemItem,
               !item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
            {
                if !currentSegment.isEmpty {
                    physicalSegments.append(currentSegment)
                    currentSegment.removeAll(keepingCapacity: true)
                }
                continue
            }
            if item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding),
               !item.isControlItem || item.tag.matchesVisibleControlItem
            {
                currentSegment.append(item)
            }
        }
        if !currentSegment.isEmpty {
            physicalSegments.append(currentSegment)
        }

        return physicalSegments.map { segment in
            segment.enumerated().sorted { lhs, rhs in
                let lhsRank = desiredRank[lhs.element.uniqueIdentifier] ?? (desiredOrder.count + lhs.offset)
                let rhsRank = desiredRank[rhs.element.uniqueIdentifier] ?? (desiredOrder.count + rhs.offset)
                return lhsRank < rhsRank
            }.map(\.element)
        }
    }

    static func nextAchievableOrderMove(
        items: [MenuBarItem],
        desiredOrder: [String],
        experimentalSystemItemHiding: Bool = false
    ) -> (item: MenuBarItem, destination: MoveDestination)? {
        let currentSegments = achievableOrderSegments(
            items: items,
            desiredOrder: [],
            experimentalSystemItemHiding: experimentalSystemItemHiding
        )
        let desiredSegments = achievableOrderSegments(
            items: items,
            desiredOrder: desiredOrder,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        )

        for (current, desired) in zip(currentSegments, desiredSegments) {
            guard current.map(\.uniqueIdentifier) != desired.map(\.uniqueIdentifier), desired.count > 1 else {
                continue
            }
            for index in 1 ..< desired.count {
                let item = desired[index]
                let destination = MoveDestination.rightOfItem(desired[index - 1])
                if !liveOrderSatisfiesDestination(
                    items: items,
                    item: item,
                    destination: destination,
                    experimentalSystemItemHiding: experimentalSystemItemHiding
                ) {
                    return (item, destination)
                }
            }
        }
        return nil
    }

    static func achievableDestination(
        items: [MenuBarItem],
        item: MenuBarItem,
        desiredOrder: [String],
        experimentalSystemItemHiding: Bool = false
    ) -> MoveDestination? {
        let currentSegments = achievableOrderSegments(
            items: items,
            desiredOrder: [],
            experimentalSystemItemHiding: experimentalSystemItemHiding
        )
        let desiredSegments = achievableOrderSegments(
            items: items,
            desiredOrder: desiredOrder,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        )

        for (current, desired) in zip(currentSegments, desiredSegments) {
            guard current.contains(where: { $0.tag.matchesIdentity(of: item.tag) }),
                  current.map(\.uniqueIdentifier) != desired.map(\.uniqueIdentifier),
                  let desiredIndex = desired.firstIndex(where: { $0.tag.matchesIdentity(of: item.tag) })
            else {
                continue
            }
            if desired.indices.contains(desiredIndex + 1) {
                return .leftOfItem(desired[desiredIndex + 1])
            }
            if desiredIndex > 0 {
                return .rightOfItem(desired[desiredIndex - 1])
            }
        }
        return nil
    }

    static func visibleControlRestoreMove(
        items: [MenuBarItem],
        desiredOrder: [String],
        experimentalSystemItemHiding: Bool = false
    ) -> (item: MenuBarItem, destination: MoveDestination)? {
        guard let item = items.first(where: { $0.tag.matchesVisibleControlItem }),
              desiredOrder.contains(item.uniqueIdentifier)
        else {
            return nil
        }

        let stranded = visibleControlIsStranded(item, among: items)
        let destination = achievableDestination(
            items: items,
            item: item,
            desiredOrder: desiredOrder,
            experimentalSystemItemHiding: experimentalSystemItemHiding
        ) ?? (stranded
            ? strandedVisibleControlRecoveryDestination(
                items: items,
                item: item,
                desiredOrder: desiredOrder,
                experimentalSystemItemHiding: experimentalSystemItemHiding
            )
            : nil)

        guard let destination else {
            return nil
        }

        if !stranded,
           liveOrderSatisfiesDestination(
               items: items,
               item: item,
               destination: destination,
               experimentalSystemItemHiding: experimentalSystemItemHiding
           )
        {
            return nil
        }

        return (item, destination)
    }

    /// Whether the visible Thaw chevron is parked off the live menu bar band or
    /// stuck at macOS's blocked sentinel (x=-1). AX sort order can still look
    /// correct while the icon is invisible to the user.
    static func visibleControlIsStranded(_ item: MenuBarItem, among peers: [MenuBarItem]) -> Bool {
        guard item.tag.matchesVisibleControlItem else { return false }
        return item.bounds.origin.x == -1 || item.isParkedOffMenuBarBand(among: peers)
    }

    /// Recovery anchor when the visible control is stranded but segment
    /// planning sees no order delta (x=-1 still sorts ahead of on-bar items).
    static func strandedVisibleControlRecoveryDestination(
        items: [MenuBarItem],
        item: MenuBarItem,
        desiredOrder: [String],
        experimentalSystemItemHiding: Bool
    ) -> MoveDestination? {
        func isOnBar(_ candidate: MenuBarItem) -> Bool {
            candidate.bounds.origin.x != -1 && !candidate.isParkedOffMenuBarBand(among: items)
        }

        guard let thawIndex = desiredOrder.firstIndex(of: item.uniqueIdentifier) else {
            return nil
        }

        for identifier in desiredOrder.dropFirst(thawIndex + 1) {
            guard let neighbor = items.first(where: { $0.uniqueIdentifier == identifier }),
                  isOnBar(neighbor),
                  neighbor.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
            else {
                continue
            }
            return .leftOfItem(neighbor)
        }

        for identifier in desiredOrder.prefix(thawIndex).reversed() {
            guard let neighbor = items.first(where: { $0.uniqueIdentifier == identifier }),
                  isOnBar(neighbor),
                  neighbor.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
            else {
                continue
            }
            return .rightOfItem(neighbor)
        }

        return nil
    }

    static func liveOrderSatisfiesSectionBoundary(
        items: [MenuBarItem],
        item: MenuBarItem,
        section: MenuBarSection.Name,
        controlItems: ControlItemPair,
        experimentalSystemItemHiding: Bool = false
    ) -> Bool {
        // Layout-anchored system items (Clock, Control Center, Siri, …) are
        // pinned to the trailing edge by the OS and cannot be moved across the
        // hidden divider with a synthetic drag. With experimental system-item
        // hiding they register as physically orderable, so without this guard
        // the section-boundary repair retries an impossible move every cycle —
        // and each failed synthetic drag partially displaces the bar (the
        // "random menu bar disappearance" / item shuffle). They never need
        // repair; concealment, not reordering, is what hides them.
        if item.tag.isLayoutAnchoredSystemItem {
            return true
        }

        if !item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding) {
            return true
        }

        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        guard let itemIndex = orderedItems.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) }),
              let hiddenDividerIndex = orderedItems.firstIndex(where: {
                  $0.tag.matchesIgnoringWindowID(controlItems.hidden.tag)
              })
        else {
            return false
        }

        switch section {
        case .visible:
            return itemIndex > hiddenDividerIndex
        case .hidden:
            guard itemIndex < hiddenDividerIndex else { return false }
            guard let alwaysHidden = controlItems.alwaysHidden else { return true }
            guard let dividerIndex = orderedItems.firstIndex(where: {
                $0.tag.matchesIgnoringWindowID(alwaysHidden.tag)
            }) else { return false }
            return itemIndex > dividerIndex
        case .alwaysHidden:
            guard let alwaysHidden = controlItems.alwaysHidden,
                  let dividerIndex = orderedItems.firstIndex(where: {
                      $0.tag.matchesIgnoringWindowID(alwaysHidden.tag)
                  })
            else { return false }
            return itemIndex < dividerIndex
        }
    }

    /// What to do when the always-hidden section is targeted but its control
    /// item divider is absent (the always-hidden section is disabled).
    enum MissingAlwaysHiddenDividerPolicy {
        /// Fall back to the hidden control item — the reconcile path, which
        /// must always produce a destination.
        case fallbackToHidden
        /// Yield nil so the caller skips the move — the plan path, which treats
        /// an absent divider as "no achievable boundary".
        case skip
    }

    /// The move destination that places an item at the leading boundary of
    /// `section`. Each section's items live to one side of that section's own
    /// control item, so the control item is the natural insertion point.
    static func sectionBoundaryDestination(
        for section: MenuBarSection.Name,
        controlItems: ControlItemPair,
        missingAlwaysHidden: MissingAlwaysHiddenDividerPolicy
    ) -> MoveDestination? {
        switch section {
        case .visible:
            return .rightOfItem(controlItems.hidden)
        case .hidden:
            return .leftOfItem(controlItems.hidden)
        case .alwaysHidden:
            if let alwaysHidden = controlItems.alwaysHidden {
                return .leftOfItem(alwaysHidden)
            }
            switch missingAlwaysHidden {
            case .fallbackToHidden: return .leftOfItem(controlItems.hidden)
            case .skip: return nil
            }
        }
    }

    static func sectionBoundaryDestination(
        for section: MenuBarSection.Name,
        controlItems: ControlItemPair
    ) -> MoveDestination? {
        sectionBoundaryDestination(for: section, controlItems: controlItems, missingAlwaysHidden: .skip)
    }

    static func dividerMoveDestination(
        items: [MenuBarItem],
        sectionAssignment: [String: MenuBarSection.Name],
        controlItems: ControlItemPair,
        experimentalSystemItemHiding: Bool = false
    ) -> MoveDestination? {
        let divider = controlItems.hidden
        guard divider.isOnScreen else { return nil }

        let orderedItems = items.filter { !$0.isSystemClone }.sorted(by: visualOrder)
        guard let dividerIndex = orderedItems.firstIndex(where: {
            $0.tag.matchesIgnoringWindowID(divider.tag)
        }) else { return nil }

        let leftBarrier = orderedItems[..<dividerIndex].lastIndex(where: {
            $0.tag.isLayoutAnchoredSystemItem &&
                !$0.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
        })
        let afterDivider = orderedItems.index(after: dividerIndex)
        let rightBarrier = afterDivider < orderedItems.endIndex
            ? orderedItems[afterDivider...].firstIndex(where: {
                $0.tag.isLayoutAnchoredSystemItem &&
                    !$0.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding)
            })
            : nil
        let segmentStart = leftBarrier.map { orderedItems.index(after: $0) } ?? orderedItems.startIndex
        let segmentEnd = rightBarrier ?? orderedItems.endIndex

        let visibleAnchor = orderedItems[segmentStart ..< segmentEnd].first { item in
            guard item.isPhysicallyOrderable(experimentalSystemItemHiding: experimentalSystemItemHiding),
                  !item.isControlItem || item.tag.matchesVisibleControlItem
            else {
                return false
            }
            return sectionAssignment[item.uniqueIdentifier] == nil
        }
        guard let visibleAnchor, divider.bounds.maxX > visibleAnchor.bounds.minX else { return nil }
        return .leftOfItem(visibleAnchor)
    }

    static func orderDescription(_ items: [MenuBarItem]) -> String {
        items
            .filter { !$0.isSystemClone }
            .sorted(by: visualOrder)
            .map { item in
                "\(item.uniqueIdentifier) title=\(item.title ?? "<nil>") frame=\(NSStringFromRect(item.bounds))"
            }
            .joined(separator: " | ")
    }

    private static func visualOrder(_ lhs: MenuBarItem, _ rhs: MenuBarItem) -> Bool {
        if lhs.bounds.midX == rhs.bounds.midX {
            return lhs.uniqueIdentifier < rhs.uniqueIdentifier
        }
        return lhs.bounds.midX < rhs.bounds.midX
    }
}
