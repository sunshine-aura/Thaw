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
