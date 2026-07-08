//
//  MenuBarBackendTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import CoreGraphics
@testable import Thaw
import XCTest

/// Characterizes the OS-specific layout policy that moved out of
/// `MenuBarItemManager` into the two `MenuBarBackend` adapters. Each method is
/// exercised against both backends so the Legacy/Assertion contrast is pinned.
@MainActor
final class MenuBarBackendTests: XCTestCase {
    private let legacy = LegacyMenuBarBackend()
    private let assertion = AssertionMenuBarBackend()

    // MARK: - relocationBounds

    func testLegacyRelocationBoundsTrustsWindowServerGeometry() {
        let ax = CGRect(x: 120, y: 0, width: 42, height: 24)
        let ws = CGRect(x: 500, y: 0, width: 42, height: 24)
        // Legacy passes the WindowServer bounds straight through, ignoring AX.
        XCTAssertEqual(legacy.relocationBounds(itemBounds: ax, windowServerBounds: ws), ws)
        // Nil WindowServer bounds means "no usable geometry" → skip the move.
        XCTAssertNil(legacy.relocationBounds(itemBounds: ax, windowServerBounds: nil))
    }

    func testAssertionRelocationBoundsUsesAXAndRejectsTransientReads() {
        let ax = CGRect(x: 120, y: 0, width: 42, height: 24)
        // Assertion uses AX bounds and ignores any WindowServer lookup.
        XCTAssertEqual(assertion.relocationBounds(itemBounds: ax, windowServerBounds: nil), ax)
        XCTAssertEqual(
            assertion.relocationBounds(itemBounds: ax, windowServerBounds: CGRect(x: 9, y: 9, width: 9, height: 9)),
            ax
        )
        // x == -1 and zero-size are the transient AX reads that must be rejected.
        XCTAssertNil(
            assertion.relocationBounds(itemBounds: CGRect(x: -1, y: 0, width: 42, height: 24), windowServerBounds: nil)
        )
        XCTAssertNil(
            assertion.relocationBounds(itemBounds: CGRect(x: 10, y: 0, width: 0, height: 24), windowServerBounds: nil)
        )
        XCTAssertNil(
            assertion.relocationBounds(itemBounds: CGRect(x: 10, y: 0, width: 42, height: 0), windowServerBounds: nil)
        )
    }

    // MARK: - shouldRetainLastGoodCache

    func testShouldRetainLastGoodCache() {
        let withControl = [
            MenuBarItem.fixture(tag: .visibleControlItem, windowID: 1),
            MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.status", title: "Status"), windowID: 2),
        ]
        let withoutControl = [
            MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.status", title: "Status"), windowID: 2),
        ]

        // Assertion: the visible control item vanished from a non-empty snapshot
        // → treat as a transient miss and retain the last-good cache.
        XCTAssertTrue(
            assertion.shouldRetainLastGoodCache(snapshotItems: withoutControl, previousCachedItems: withControl)
        )
        // Still present → not a miss.
        XCTAssertFalse(
            assertion.shouldRetainLastGoodCache(snapshotItems: withControl, previousCachedItems: withControl)
        )
        // Empty snapshot → never retain (there is nothing to compare against).
        XCTAssertFalse(
            assertion.shouldRetainLastGoodCache(snapshotItems: [], previousCachedItems: withControl)
        )
        // Legacy never retains — its cache path has no such transient miss.
        XCTAssertFalse(
            legacy.shouldRetainLastGoodCache(snapshotItems: withoutControl, previousCachedItems: withControl)
        )
    }

    // MARK: - canSynthesizeControlItems

    func testCanSynthesizeControlItems() {
        let withControl = [
            MenuBarItem.fixture(tag: .visibleControlItem, windowID: 1),
            MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.status", title: "Status"), windowID: 2),
        ]
        let withoutControl = [
            MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.status", title: "Status"), windowID: 2),
        ]

        XCTAssertTrue(assertion.canSynthesizeControlItems(snapshotItems: withControl))
        XCTAssertFalse(assertion.canSynthesizeControlItems(snapshotItems: withoutControl))
        // Legacy discovers real divider windows; it never synthesizes them.
        XCTAssertFalse(legacy.canSynthesizeControlItems(snapshotItems: withControl))
    }

    // MARK: - windowIDsChanged

    func testAssertionWindowIDsChangedNeverFires() {
        // Synthetic-ID churn on the assertion backend must never advance the gate.
        XCTAssertFalse(
            assertion.windowIDsChanged(
                previous: [10, 11, 12],
                current: [10, 11],
                previousDisplayID: 1,
                currentDisplayID: 1
            )
        )
    }

    func testLegacyWindowIDsChangedFiresOnDisappearanceButNotDisplaySwitch() {
        // A previously-seen window disappeared on the same display → real change.
        XCTAssertTrue(
            legacy.windowIDsChanged(previous: [10, 11, 12], current: [10, 11], previousDisplayID: 1, currentDisplayID: 1)
        )
        // Active display switched → not an item quit, must not fire.
        XCTAssertFalse(
            legacy.windowIDsChanged(previous: [10, 11, 12], current: [20, 21, 22], previousDisplayID: 1, currentDisplayID: 2)
        )
        // First cycle (empty previous) → nothing to diff.
        XCTAssertFalse(
            legacy.windowIDsChanged(previous: [], current: [10, 11], previousDisplayID: 1, currentDisplayID: 1)
        )
    }

    // MARK: - layoutMembershipDiverged (Legacy spatial classification)

    /// Hidden divider at x=100 (w=10); an item right of it reads visible-side.
    private func legacyControlPair(withAlwaysHidden: Bool = false) -> MenuBarItemManager.ControlItemPair {
        .fixture(
            hiddenAt: CGRect(x: 100, y: 0, width: 10, height: 22),
            alwaysHiddenAt: withAlwaysHidden ? CGRect(x: 20, y: 0, width: 10, height: 22) : nil
        )
    }

    func testLegacyDivergesWhenItemSpatiallyLeftOfSavedSection() {
        let controlItems = legacyControlPair()
        // Item sits right of the hidden divider → currently visible-side.
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.a", title: "Foo"),
            windowID: 5,
            bounds: CGRect(x: 200, y: 0, width: 24, height: 22)
        )
        // Saved as hidden, but currently visible → divergence.
        XCTAssertTrue(
            legacy.layoutMembershipDiverged(
                savedSectionByBaseID: ["com.test.a:Foo": .hidden],
                items: [item],
                controlItems: controlItems,
                hider: nil
            )
        )
        // Saved as visible, matches current geometry → no divergence.
        XCTAssertFalse(
            legacy.layoutMembershipDiverged(
                savedSectionByBaseID: ["com.test.a:Foo": .visible],
                items: [item],
                controlItems: controlItems,
                hider: nil
            )
        )
    }

    func testLegacyClassifiesHiddenAndAlwaysHiddenRegions() {
        let controlItems = legacyControlPair(withAlwaysHidden: true)
        // Between always-hidden (maxX=30) and hidden (minX=100) → hidden region.
        let hiddenItem = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.a", title: "Mid"),
            windowID: 6,
            bounds: CGRect(x: 50, y: 0, width: 24, height: 22)
        )
        // Left of the always-hidden divider (minX=20) → always-hidden region.
        let ahItem = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.a", title: "Left"),
            windowID: 7,
            bounds: CGRect(x: 0, y: 0, width: 15, height: 22)
        )
        XCTAssertFalse(
            legacy.layoutMembershipDiverged(
                savedSectionByBaseID: ["com.test.a:Mid": .hidden, "com.test.a:Left": .alwaysHidden],
                items: [hiddenItem, ahItem],
                controlItems: controlItems,
                hider: nil
            )
        )
        // Same items, saved sections swapped → both diverge (returns on first).
        XCTAssertTrue(
            legacy.layoutMembershipDiverged(
                savedSectionByBaseID: ["com.test.a:Mid": .visible, "com.test.a:Left": .visible],
                items: [hiddenItem, ahItem],
                controlItems: controlItems,
                hider: nil
            )
        )
    }

    // MARK: - controlItemEnforcementStrategy

    func testControlItemEnforcementStrategyPerBackend() {
        XCTAssertEqual(legacy.controlItemEnforcementStrategy, .legacyDividerSwap)
        XCTAssertEqual(assertion.controlItemEnforcementStrategy, .assertionDividerReorder)
    }

    func testLayoutResetStrategyPerBackend() {
        XCTAssertEqual(legacy.layoutResetStrategy, .legacyMoveToHidden)
        XCTAssertEqual(assertion.layoutResetStrategy, .assignmentSweep)
    }

    func testMovePathAndDividerTargetPolicyPerBackend() {
        XCTAssertEqual(legacy.preferredMovePath, .legacyWindowServer)
        XCTAssertTrue(legacy.allowsSectionBoundaryDividerTarget(allowExplicitOptIn: false))
        XCTAssertTrue(legacy.allowsSectionBoundaryDividerTarget(allowExplicitOptIn: true))

        XCTAssertEqual(assertion.preferredMovePath, .preferredPositionsThenCommandDrag)
        XCTAssertFalse(assertion.allowsSectionBoundaryDividerTarget(allowExplicitOptIn: false))
        XCTAssertTrue(assertion.allowsSectionBoundaryDividerTarget(allowExplicitOptIn: true))
    }

    func testResetExecutionMatrixPerBackend() {
        XCTAssertEqual(legacy.resetExecution(for: .freshInstallHidden), .legacyPhysicalMoves(.toHidden))
        XCTAssertEqual(legacy.resetExecution(for: .allVisible), .legacyPhysicalMoves(.toVisible))
        XCTAssertEqual(legacy.resetExecution(for: .allAlwaysHidden), .legacyPhysicalMoves(.toVisible))

        XCTAssertEqual(assertion.resetExecution(for: .freshInstallHidden), .assignmentSweep(.hidden))
        XCTAssertEqual(assertion.resetExecution(for: .allVisible), .assignmentSweep(nil))
        XCTAssertEqual(assertion.resetExecution(for: .allAlwaysHidden), .assignmentSweep(.alwaysHidden))
    }

    func testItemCacheSignaturePerBackend() {
        let alphaLeft = item("Alpha", bundleID: "com.example.alpha", x: 100, windowID: 1510)
        let betaRight = item("Beta", bundleID: "com.example.beta", x: 140, windowID: 1511)
        let alphaRight = item("Alpha", bundleID: "com.example.alpha", x: 140, windowID: 1510)
        let betaLeft = item("Beta", bundleID: "com.example.beta", x: 100, windowID: 1511)

        XCTAssertNil(legacy.itemCacheSignature([alphaLeft, betaRight]))

        let original = assertion.itemCacheSignature([alphaLeft, betaRight])
        let sameGeometryShuffled = assertion.itemCacheSignature([betaRight, alphaLeft])
        let reordered = assertion.itemCacheSignature([alphaRight, betaLeft])

        XCTAssertEqual(original, sameGeometryShuffled)
        XCTAssertNotEqual(original, reordered)
    }

    func testLayoutStrategiesPerBackend() {
        XCTAssertEqual(legacy.profileLayoutStrategy, .legacyBulkMove)
        XCTAssertEqual(assertion.profileLayoutStrategy, .assignmentApply)
        XCTAssertEqual(legacy.savedLayoutRestoreStrategy, .spatialBulkApply)
        XCTAssertEqual(assertion.savedLayoutRestoreStrategy, .visibleControlOrderOnly)
    }

    func testHeuristicFlagsPerBackend() {
        XCTAssertTrue(legacy.classifiesSectionByDividerGeometry)
        XCTAssertFalse(assertion.classifiesSectionByDividerGeometry)
        XCTAssertFalse(legacy.shouldCoalesceCacheRerun)
        XCTAssertTrue(assertion.shouldCoalesceCacheRerun)
        XCTAssertTrue(legacy.usesProfileWindowIDRelaunchHeuristic)
        XCTAssertFalse(assertion.usesProfileWindowIDRelaunchHeuristic)
    }

    // MARK: - persistLayoutSnapshot

    func testPersistLayoutSnapshotActionPerBackend() {
        XCTAssertEqual(legacy.persistLayoutSnapshot(shouldPersist: true), .saveSpatialOrder)
        XCTAssertEqual(assertion.persistLayoutSnapshot(shouldPersist: true), .mirrorSectionOrder)
        // Gate closed → neither backend persists.
        XCTAssertEqual(legacy.persistLayoutSnapshot(shouldPersist: false), .none)
        XCTAssertEqual(assertion.persistLayoutSnapshot(shouldPersist: false), .none)
    }

    func testLegacyExcludesParkedOffBandItems() {
        let controlItems = legacyControlPair()
        // Parked off the bar band (midY well above 80) → excluded from the check
        // even though its X would classify it visible-side against a hidden save.
        let parked = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.a", title: "Parked"),
            windowID: 8,
            bounds: CGRect(x: 200, y: 1400, width: 24, height: 22)
        )
        XCTAssertFalse(
            legacy.layoutMembershipDiverged(
                savedSectionByBaseID: ["com.test.a:Parked": .hidden],
                items: [parked],
                controlItems: controlItems,
                hider: nil
            )
        )
    }

    private func item(
        _ title: String,
        bundleID: String,
        x: CGFloat,
        windowID: CGWindowID
    ) -> MenuBarItem {
        MenuBarItem.fixture(
            tag: .appItem(bundleID: bundleID, title: title),
            windowID: windowID,
            bounds: CGRect(x: x, y: 0, width: 24, height: 22)
        )
    }
}
