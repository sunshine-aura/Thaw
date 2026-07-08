//
//  MenuBarBackend.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics

/// Operating-system-specific menu-bar section behavior.
///
/// Two adapters make this a real seam: legacy macOS uses physical divider
/// reflow, while macOS 27 uses assertion-backed visibility and assignment-based
/// cache reconstruction.
protocol MenuBarBackend: Sendable {
    var usesAssertionHiding: Bool { get }
    var supportsLegacySectionHiding: Bool { get }

    @MainActor
    func rebucket(
        _ cache: MenuBarItemManager.ItemCache,
        hider: SimpleItemHider?,
        allowsAlwaysHidden: Bool
    ) -> MenuBarItemManager.ItemCache

    func capturableSections(
        from requested: [MenuBarSection.Name],
        revealedSection: MenuBarSection.Name?
    ) -> [MenuBarSection.Name]

    /// Selects the bounds source used to validate an automatic relocation, or
    /// nil when the candidate has no usable bounds and the move should be
    /// skipped. Legacy trusts the WindowServer geometry; the assertion backend
    /// uses the item's own AX bounds (synthetic window IDs make a WindowServer
    /// lookup invalid) and rejects the `x == -1` / zero-size transient reads.
    nonisolated func relocationBounds(itemBounds: CGRect, windowServerBounds: CGRect?) -> CGRect?

    /// Whether an AX snapshot that is missing Thaw's own visible control item
    /// should be treated as a transient miss so the last-good cache is retained
    /// rather than overwritten with a bad frame.
    nonisolated func shouldRetainLastGoodCache(snapshotItems: [MenuBarItem], previousCachedItems: [MenuBarItem]) -> Bool

    /// Whether Thaw may synthesize its zero-length divider control items from
    /// the snapshot (only when the visible control item is actually present).
    nonisolated func canSynthesizeControlItems(snapshotItems: [MenuBarItem]) -> Bool

    /// Whether a windowID-set difference between two cache cycles is a genuine
    /// change that should trigger a saved-layout re-apply, or merely an artifact
    /// (active-display switch on legacy; synthetic-ID churn on the assertion
    /// backend, where logical identity and assignment divergence own restore
    /// detection instead).
    nonisolated func windowIDsChanged(
        previous: Set<CGWindowID>,
        current: Set<CGWindowID>,
        previousDisplayID: CGDirectDisplayID?,
        currentDisplayID: CGDirectDisplayID?
    ) -> Bool

    /// Whether the current bar differs from the saved layout in section
    /// membership — the secondary `applySavedLayout` trigger for ambient drift
    /// that leaves window IDs intact. `savedSectionByBaseID` maps each saved
    /// item's `namespace:title` base identifier to its saved section.
    ///
    /// Legacy classifies each item's section spatially from its bounds relative
    /// to the divider control items; the assertion backend reads membership from
    /// ``SimpleItemHider/section(for:)`` because macOS 27 membership is
    /// assignment-driven and AX X-coordinates still read hidden-side after an
    /// assertion reflow. Both exclude non-concealable Apple system items and
    /// items parked off the bar band, which would otherwise never converge and
    /// re-fire the bulk apply every cache cycle.
    @MainActor
    func layoutMembershipDiverged(
        savedSectionByBaseID: [String: MenuBarSection.Name],
        items: [MenuBarItem],
        controlItems: MenuBarItemManager.ControlItemPair,
        hider: SimpleItemHider?
    ) -> Bool

    /// Which layout-snapshot persistence to run when the shared persist gate is
    /// open (`shouldPersist`). Legacy saves the position-derived spatial order;
    /// the assertion backend mirrors the assignment-driven section order.
    nonisolated func persistLayoutSnapshot(shouldPersist: Bool) -> LayoutSnapshotAction

    /// Which section-divider enforcement model applies on this OS.
    nonisolated var controlItemEnforcementStrategy: ControlItemEnforcementStrategy { get }

    nonisolated var preferredMovePath: PreferredMovePath { get }

    nonisolated func allowsSectionBoundaryDividerTarget(allowExplicitOptIn: Bool) -> Bool

    nonisolated func resetExecution(for target: SectionResetTarget) -> LayoutResetExecution

    nonisolated func itemCacheSignature(_ items: [MenuBarItem]) -> [String]?

    nonisolated var profileLayoutStrategy: ProfileLayoutStrategy { get }

    nonisolated var savedLayoutRestoreStrategy: SavedLayoutRestoreStrategy { get }

    nonisolated var classifiesSectionByDividerGeometry: Bool { get }

    nonisolated var shouldCoalesceCacheRerun: Bool { get }

    nonisolated var usesProfileWindowIDRelaunchHeuristic: Bool { get }
}

struct LegacyMenuBarBackend: MenuBarBackend {
    let usesAssertionHiding = false
    let supportsLegacySectionHiding = true

    @MainActor
    func rebucket(
        _ cache: MenuBarItemManager.ItemCache,
        hider _: SimpleItemHider?,
        allowsAlwaysHidden _: Bool
    ) -> MenuBarItemManager.ItemCache {
        cache
    }

    func capturableSections(
        from requested: [MenuBarSection.Name],
        revealedSection _: MenuBarSection.Name?
    ) -> [MenuBarSection.Name] {
        requested
    }

    nonisolated func relocationBounds(itemBounds _: CGRect, windowServerBounds: CGRect?) -> CGRect? {
        windowServerBounds
    }

    nonisolated func shouldRetainLastGoodCache(
        snapshotItems _: [MenuBarItem],
        previousCachedItems _: [MenuBarItem]
    ) -> Bool {
        false
    }

    nonisolated func canSynthesizeControlItems(snapshotItems _: [MenuBarItem]) -> Bool {
        false
    }

    nonisolated func windowIDsChanged(
        previous: Set<CGWindowID>,
        current: Set<CGWindowID>,
        previousDisplayID: CGDirectDisplayID?,
        currentDisplayID: CGDirectDisplayID?
    ) -> Bool {
        // First cycle: no prior frame to diff against.
        guard !previous.isEmpty else { return false }
        // The active menu bar display moved to another screen. With separate
        // Spaces the prior display's windows are no longer on the active space,
        // so they read as missing even though the same logical items are still
        // present elsewhere. Not an item quit; do not advance the gate. Only
        // suppress when both displays are known and genuinely differ, so an
        // unknown display falls back to the plain disappearance signal.
        if let previousDisplayID, let currentDisplayID, previousDisplayID != currentDisplayID {
            return false
        }
        return !previous.isSubset(of: current)
    }

    @MainActor
    func layoutMembershipDiverged(
        savedSectionByBaseID: [String: MenuBarSection.Name],
        items: [MenuBarItem],
        controlItems: MenuBarItemManager.ControlItemPair,
        hider _: SimpleItemHider?
    ) -> Bool {
        let hiddenMinX = controlItems.hidden.bounds.minX
        let hiddenMaxX = controlItems.hidden.bounds.maxX
        let ahBounds = controlItems.alwaysHidden?.bounds

        // Non-concealable Apple system items (Sound/Wi-Fi/Spotlight/Siri/…) report
        // `canBeHidden` but can neither be bundle-concealed nor reliably dragged to
        // the hidden side, so an assigned-hidden one is *perpetually* "in the wrong
        // section". Including it here made divergence never clear, re-firing
        // applyProfileLayout every cache cycle (the runaway loop that thrashed the
        // divider and hijacked the cursor). They're managed best-effort elsewhere;
        // exclude them from divergence so only achievable (third-party) drift
        // triggers a re-apply.
        for item in items where !item.isControlItem && item.canBeHidden && item.isMovable
            && !item.isNonConcealableSystemItem
        {
            // Assertion reflows park items off the bar band briefly; their X
            // still reads hidden-side and would false-trigger a bulk re-apply.
            guard !item.isParkedOffMenuBarBand(among: items) else { continue }

            let baseID = "\(item.tag.namespace):\(item.tag.title)"
            guard let expectedSection = savedSectionByBaseID[baseID] else {
                continue
            }

            let currentSection: MenuBarSection.Name? = if item.bounds.minX >= hiddenMaxX {
                .visible
            } else if let ahBounds, item.bounds.maxX <= ahBounds.minX {
                .alwaysHidden
            } else if let ahBounds, item.bounds.minX >= ahBounds.maxX, item.bounds.maxX <= hiddenMinX {
                .hidden
            } else if ahBounds == nil, item.bounds.maxX <= hiddenMinX {
                .hidden
            } else {
                nil
            }

            guard let currentSection else { continue }
            if currentSection != expectedSection {
                return true
            }
        }
        return false
    }

    nonisolated func persistLayoutSnapshot(shouldPersist: Bool) -> LayoutSnapshotAction {
        shouldPersist ? .saveSpatialOrder : .none
    }

    nonisolated var controlItemEnforcementStrategy: ControlItemEnforcementStrategy {
        .legacyDividerSwap
    }

    nonisolated var preferredMovePath: PreferredMovePath {
        .legacyWindowServer
    }

    nonisolated func allowsSectionBoundaryDividerTarget(allowExplicitOptIn _: Bool) -> Bool {
        true
    }

    nonisolated func resetExecution(for target: SectionResetTarget) -> LayoutResetExecution {
        switch target {
        case .freshInstallHidden:
            .legacyPhysicalMoves(.toHidden)
        case .allVisible, .allAlwaysHidden:
            .legacyPhysicalMoves(.toVisible)
        }
    }

    nonisolated func itemCacheSignature(_: [MenuBarItem]) -> [String]? {
        nil
    }

    nonisolated var profileLayoutStrategy: ProfileLayoutStrategy {
        .legacyBulkMove
    }

    nonisolated var savedLayoutRestoreStrategy: SavedLayoutRestoreStrategy {
        .spatialBulkApply
    }

    nonisolated var classifiesSectionByDividerGeometry: Bool {
        true
    }

    nonisolated var shouldCoalesceCacheRerun: Bool {
        false
    }

    nonisolated var usesProfileWindowIDRelaunchHeuristic: Bool {
        true
    }
}

struct AssertionMenuBarBackend: MenuBarBackend {
    let usesAssertionHiding = true
    let supportsLegacySectionHiding = false

    @MainActor
    func rebucket(
        _ cache: MenuBarItemManager.ItemCache,
        hider: SimpleItemHider?,
        allowsAlwaysHidden: Bool
    ) -> MenuBarItemManager.ItemCache {
        guard let hider else { return cache }
        return CacheRebucketter.rebucket(
            cache,
            sectionFor: { hider.section(for: $0) },
            sectionAssignment: hider.sectionAssignment,
            allowsAlwaysHidden: allowsAlwaysHidden,
            retainedSnapshotFor: { hider.snapshot(for: $0) },
            orderedItems: { hider.ordered($0, in: $1) }
        )
    }

    func capturableSections(
        from requested: [MenuBarSection.Name],
        revealedSection: MenuBarSection.Name?
    ) -> [MenuBarSection.Name] {
        requested.filter { section in
            switch (section, revealedSection) {
            case (.visible, _), (.hidden, .hidden), (.hidden, .alwaysHidden), (.alwaysHidden, .alwaysHidden):
                true
            default:
                false
            }
        }
    }

    nonisolated func relocationBounds(itemBounds: CGRect, windowServerBounds _: CGRect?) -> CGRect? {
        guard itemBounds.origin.x != -1,
              itemBounds.width > 0,
              itemBounds.height > 0
        else {
            return nil
        }
        return itemBounds
    }

    nonisolated func shouldRetainLastGoodCache(
        snapshotItems: [MenuBarItem],
        previousCachedItems: [MenuBarItem]
    ) -> Bool {
        guard !snapshotItems.isEmpty else { return false }
        let hadVisibleControlItem = previousCachedItems.contains { $0.tag.matchesVisibleControlItem }
        let hasVisibleControlItem = snapshotItems.contains { $0.tag.matchesVisibleControlItem }
        return hadVisibleControlItem && !hasVisibleControlItem
    }

    nonisolated func canSynthesizeControlItems(snapshotItems: [MenuBarItem]) -> Bool {
        snapshotItems.contains { $0.tag.matchesVisibleControlItem }
    }

    nonisolated func windowIDsChanged(
        previous _: Set<CGWindowID>,
        current _: Set<CGWindowID>,
        previousDisplayID _: CGDirectDisplayID?,
        currentDisplayID _: CGDirectDisplayID?
    ) -> Bool {
        // macOS 27's AX provider synthesizes IDs from logical item identity,
        // and control items are removed from `items` before this gate runs.
        // Comparing that managed-item set with the earlier all-item snapshot
        // makes the extracted divider look like a quit on every cache cycle.
        // Logical identity and assignment divergence own restore detection on
        // this backend, so real-window disappearance is never a signal here.
        false
    }

    @MainActor
    func layoutMembershipDiverged(
        savedSectionByBaseID: [String: MenuBarSection.Name],
        items: [MenuBarItem],
        controlItems _: MenuBarItemManager.ControlItemPair,
        hider: SimpleItemHider?
    ) -> Bool {
        // macOS 27: section membership is assignment-driven, not spatial. Items
        // left of the hidden control still read as "hidden-side" in AX even when
        // SimpleItemHider assigns them visible — false-triggering a bulk reorder
        // on every cache cycle after assertion reflow.
        guard let hider else { return false }
        for item in items where !item.isControlItem && item.canBeHidden && item.isMovable
            && !item.isNonConcealableSystemItem
        {
            guard !item.isParkedOffMenuBarBand(among: items) else { continue }

            let baseID = "\(item.tag.namespace):\(item.tag.title)"
            guard let expectedSection = savedSectionByBaseID[baseID] else {
                continue
            }

            let currentSection = hider.section(for: item)
            if currentSection != expectedSection {
                return true
            }
        }
        return false
    }

    nonisolated func persistLayoutSnapshot(shouldPersist: Bool) -> LayoutSnapshotAction {
        shouldPersist ? .mirrorSectionOrder : .none
    }

    nonisolated var controlItemEnforcementStrategy: ControlItemEnforcementStrategy {
        .assertionDividerReorder
    }

    nonisolated var preferredMovePath: PreferredMovePath {
        .preferredPositionsThenCommandDrag
    }

    nonisolated func allowsSectionBoundaryDividerTarget(allowExplicitOptIn: Bool) -> Bool {
        allowExplicitOptIn
    }

    nonisolated func resetExecution(for target: SectionResetTarget) -> LayoutResetExecution {
        switch target {
        case .freshInstallHidden:
            .assignmentSweep(.hidden)
        case .allVisible:
            .assignmentSweep(nil)
        case .allAlwaysHidden:
            .assignmentSweep(.alwaysHidden)
        }
    }

    nonisolated func itemCacheSignature(_ items: [MenuBarItem]) -> [String]? {
        MenuBarItem.sortByVisualCenterThenIdentifier(items.filter { !$0.isSystemClone })
            .map(\.uniqueIdentifier)
    }

    nonisolated var profileLayoutStrategy: ProfileLayoutStrategy {
        .assignmentApply
    }

    nonisolated var savedLayoutRestoreStrategy: SavedLayoutRestoreStrategy {
        .visibleControlOrderOnly
    }

    nonisolated var classifiesSectionByDividerGeometry: Bool {
        false
    }

    nonisolated var shouldCoalesceCacheRerun: Bool {
        true
    }

    nonisolated var usesProfileWindowIDRelaunchHeuristic: Bool {
        false
    }
}

enum MenuBarBackendFactory {
    static let current: any MenuBarBackend = {
        if #available(macOS 27, *) {
            return AssertionMenuBarBackend()
        } else {
            return LegacyMenuBarBackend()
        }
    }()

    /// Selects the backend implied by a `usesVisibilityRestrictions` flag,
    /// independent of the host OS. Callers that only carry the boolean (the
    /// image cache's capture-section resolver and its tests) route through the
    /// same adapters as ``current`` instead of hand-constructing one.
    static func backend(usesVisibilityRestrictions: Bool) -> any MenuBarBackend {
        usesVisibilityRestrictions ? AssertionMenuBarBackend() : LegacyMenuBarBackend()
    }
}
