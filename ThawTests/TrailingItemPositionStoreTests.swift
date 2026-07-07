//
//  TrailingItemPositionStoreTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@MainActor
final class TrailingItemPositionStoreTests: XCTestCase {
    // Key-resolution cases live in TrailingItemPreferredPositionsKeysTests (the
    // shared source of truth this store delegates to). This suite covers only
    // the store's own hide-specific behavior: computeRestoreWeight and the
    // hideItems/showItems instance path.

    // MARK: - computeRestoreWeight

    func testComputeRestoreWeightMidpointBetweenNeighbors() {
        let left = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Left"),
            windowID: 20,
            bounds: CGRect(x: 0, y: 0, width: 24, height: 22)
        )
        let middle = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Middle"),
            windowID: 21,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let right = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Right"),
            windowID: 22,
            bounds: CGRect(x: 60, y: 0, width: 24, height: 22)
        )
        let existingKeys = ["status:com.test.A::Left", "status:com.test.A::Right"]
        let positions = ["status:com.test.A::Left": 100, "status:com.test.A::Right": 200]

        let weight = TrailingItemPositionStore.computeRestoreWeight(
            for: middle,
            savedWeight: 999,
            existingKeys: existingKeys,
            positions: positions,
            allItems: [left, middle, right]
        )
        XCTAssertEqual(weight, 150)
    }

    func testComputeRestoreWeightNeighborsOneApartReturnsSavedWeight() {
        // Midpoint between 100 and 101 equals lo (100) — the mid != lo && mid
        // != hi guard rejects it and falls back to the saved weight.
        let left = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Left"),
            windowID: 20,
            bounds: CGRect(x: 0, y: 0, width: 24, height: 22)
        )
        let middle = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Middle"),
            windowID: 21,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let right = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Right"),
            windowID: 22,
            bounds: CGRect(x: 60, y: 0, width: 24, height: 22)
        )
        let existingKeys = ["status:com.test.A::Left", "status:com.test.A::Right"]
        let positions = ["status:com.test.A::Left": 100, "status:com.test.A::Right": 101]

        let weight = TrailingItemPositionStore.computeRestoreWeight(
            for: middle,
            savedWeight: 999,
            existingKeys: existingKeys,
            positions: positions,
            allItems: [left, middle, right]
        )
        XCTAssertEqual(weight, 999)
    }

    func testComputeRestoreWeightOnlyLeftNeighborStepsOutward() {
        let left = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Left"),
            windowID: 20,
            bounds: CGRect(x: 0, y: 0, width: 24, height: 22)
        )
        let restored = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Restored"),
            windowID: 21,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let existingKeys = ["status:com.test.A::Left"]
        let positions = ["status:com.test.A::Left": 100]

        let weight = TrailingItemPositionStore.computeRestoreWeight(
            for: restored,
            savedWeight: 999,
            existingKeys: existingKeys,
            positions: positions,
            allItems: [left, restored]
        )
        XCTAssertEqual(weight, 110)
    }

    // MARK: - hideItems / showItems (instance behavior via injected Environment)

    func testHideItemsRemovesKeyAndRecordsWeight() {
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Item"),
            windowID: 30,
            bounds: CGRect(x: 0, y: 0, width: 24, height: 22)
        )
        var written: [String: Int]?
        let env = TrailingItemPositionStore.Environment(
            readPositions: { ["status:com.test.A::Item": 150] },
            writePositions: { written = $0 }
        )
        let store = TrailingItemPositionStore(environment: env)

        let removed = store.hideItems([item])

        XCTAssertEqual(removed, ["status:com.test.A::Item"])
        XCTAssertEqual(written, [:])
        XCTAssertTrue(store.hasHiddenItems)
    }

    func testShowItemsRestoresKeyWithNeighborWeight() {
        let left = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Left"),
            windowID: 40,
            bounds: CGRect(x: 0, y: 0, width: 24, height: 22)
        )
        let item = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Item"),
            windowID: 41,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let right = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: "Right"),
            windowID: 42,
            bounds: CGRect(x: 60, y: 0, width: 24, height: 22)
        )

        // A fixed snapshot of the live dictionary, still carrying the item's
        // own key (as it would look immediately before the item is hidden,
        // and as MenuBarAgent's own bookkeeping would look once it re-adds
        // the item under the same title/bundle-ID). `writePositions` only
        // records what was written; it does not feed back into subsequent
        // reads, so each call starts from this same snapshot.
        var written: [String: Int]?
        let env = TrailingItemPositionStore.Environment(
            readPositions: {
                [
                    "status:com.test.A::Left": 100,
                    "status:com.test.A::Item": 150,
                    "status:com.test.A::Right": 200,
                ]
            },
            writePositions: { written = $0 }
        )
        let store = TrailingItemPositionStore(environment: env)

        let removed = store.hideItems([item])
        XCTAssertEqual(removed, ["status:com.test.A::Item"])
        XCTAssertNil(written?["status:com.test.A::Item"])
        XCTAssertTrue(store.hasHiddenItems)

        let restored = store.showItems([item], allItems: [left, item, right])

        XCTAssertEqual(restored, ["status:com.test.A::Item"])
        // Restored between its Left (100) and Right (200) neighbors.
        XCTAssertEqual(written?["status:com.test.A::Item"], 150)
        XCTAssertFalse(store.hasHiddenItems)
    }
}
