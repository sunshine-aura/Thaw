//
//  LayoutResetDirectionTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

final class LayoutResetDirectionTests: XCTestCase {
    func testTowardHiddenTreatsVisibleAndAlwaysHiddenItemsAsNotYetInTarget() {
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.app", title: "Item"), windowID: 10)
        let hidden = MenuBarItem.fixture(tag: .hiddenControlItem, windowID: 1)
        let direction = MenuBarItemManager.LayoutResetDirection.towardHidden(anchor: hidden)
        let hiddenBounds = CGRect(x: 100, y: 0, width: 20, height: 22)
        let alwaysHiddenBounds = CGRect(x: 40, y: 0, width: 20, height: 22)

        XCTAssertTrue(
            direction.isNotYetInTarget(
                item: item,
                bounds: CGRect(x: 130, y: 0, width: 20, height: 22),
                hiddenBounds: hiddenBounds,
                alwaysHiddenBounds: alwaysHiddenBounds
            )
        )
        XCTAssertTrue(
            direction.isNotYetInTarget(
                item: item,
                bounds: CGRect(x: 10, y: 0, width: 20, height: 22),
                hiddenBounds: hiddenBounds,
                alwaysHiddenBounds: alwaysHiddenBounds
            )
        )
        XCTAssertFalse(
            direction.isNotYetInTarget(
                item: item,
                bounds: CGRect(x: 70, y: 0, width: 20, height: 22),
                hiddenBounds: hiddenBounds,
                alwaysHiddenBounds: alwaysHiddenBounds
            )
        )
    }

    func testTowardVisibleTreatsItemsLeftOfHiddenDividerAsNotYetInTarget() {
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "com.example.app", title: "Item"), windowID: 10)
        let hidden = MenuBarItem.fixture(tag: .hiddenControlItem, windowID: 1)
        let direction = MenuBarItemManager.LayoutResetDirection.towardVisible(hiddenDivider: hidden)
        let hiddenBounds = CGRect(x: 100, y: 0, width: 20, height: 22)

        XCTAssertTrue(
            direction.isNotYetInTarget(
                item: item,
                bounds: CGRect(x: 80, y: 0, width: 20, height: 22),
                hiddenBounds: hiddenBounds,
                alwaysHiddenBounds: CGRect(x: 40, y: 0, width: 20, height: 22)
            )
        )
        XCTAssertFalse(
            direction.isNotYetInTarget(
                item: item,
                bounds: CGRect(x: 120, y: 0, width: 20, height: 22),
                hiddenBounds: hiddenBounds,
                alwaysHiddenBounds: CGRect(x: 40, y: 0, width: 20, height: 22)
            )
        )
    }
}
