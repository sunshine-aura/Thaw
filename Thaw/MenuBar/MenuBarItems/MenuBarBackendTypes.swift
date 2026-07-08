//
//  MenuBarBackendTypes.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

/// The layout-snapshot persistence a backend wants the manager to perform when
/// the shared "should persist now" gate is open. The manager owns the actual
/// I/O (and the live blocked-items / cross-display guards); the backend only
/// decides which policy applies.
enum LayoutSnapshotAction: Equatable {
    /// Persist nothing this cycle.
    case none
    /// macOS 27: mirror the curated section order out of `itemCache` into
    /// `savedSectionOrder` (membership is owned by `SimpleItemHider`).
    case mirrorSectionOrder
    /// Legacy: derive and save the section order from item positions, subject to
    /// the manager's blocked-item (`x == -1`) and cross-display guards.
    case saveSpatialOrder
}

/// How the manager should keep the section-divider control items ordered. The
/// backend selects the model; the manager runs the (async) moves, since the
/// enforcement interleaves synthetic-drag execution with the divider-thrash
/// guard and per-move error handling.
enum ControlItemEnforcementStrategy: Equatable {
    /// macOS 27: dividers are assignment-anchored and reordered via the planner
    /// (`LayoutPlanner.dividerMoveDestination`) behind the thrash guard.
    case assertionDividerReorder
    /// Legacy: physically swap the always-hidden divider left of the hidden
    /// divider when their geometry is inverted.
    case legacyDividerSwap
}

enum PreferredMovePath: Equatable {
    case legacyWindowServer
    case preferredPositionsThenCommandDrag
}

enum SectionResetTarget: Equatable {
    case freshInstallHidden
    case allVisible
    case allAlwaysHidden
}

enum LayoutResetExecution: Equatable {
    case assignmentSweep(MenuBarSection.Name?)
    case legacyPhysicalMoves(MenuBarItemManager.LayoutResetDirection)
}

enum ProfileLayoutStrategy: Equatable {
    case legacyBulkMove
    case assignmentApply
}

enum SavedLayoutRestoreStrategy: Equatable {
    case spatialBulkApply
    case visibleControlOrderOnly
}
