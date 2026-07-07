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
}
