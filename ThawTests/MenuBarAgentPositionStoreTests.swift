//
//  MenuBarAgentPositionStoreTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

@available(macOS 27, *)
@MainActor
final class MenuBarAgentPositionStoreTests: XCTestCase {
    // Key-resolution and midpoint cases live in
    // TrailingItemPreferredPositionsKeysTests (the shared source of truth this
    // store delegates to). This suite covers only the store's own
    // orchestration: neighborItems, move, and applyOrder.

    // MARK: - neighborItems

    func testRightOfItemBracketsAnchorAndRightNeighbor() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)
        let result = MenuBarAgentPositionStore.neighborItems(
            forMoving: a,
            to: .rightOfItem(target),
            liveItems: [a, target, c]
        )
        XCTAssertEqual(result?.anchor.tag.title, "T")
        XCTAssertEqual(result?.far?.tag.title, "C")
    }

    func testLeftOfItemFarNeighborNilAtRunStart() {
        // Anchor is leftmost after the moved item is removed → no far neighbor.
        let moved = item("M", x: 90)
        let target = item("T", x: 0)
        let c = item("C", x: 30)
        let result = MenuBarAgentPositionStore.neighborItems(
            forMoving: moved,
            to: .leftOfItem(target),
            liveItems: [target, c, moved]
        )
        XCTAssertEqual(result?.anchor.tag.title, "T")
        XCTAssertNil(result?.far)
    }

    // MARK: - move orchestration

    func testMoveWritesMidpointAndNudges() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)

        var written: [String: Int]?
        var nudged = false
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::A": 50, "status:A::T": 100, "status:A::C": 200] },
            writePositions: { written = $0 },
            nudgeAgent: { nudged = true }
        )

        let applied = MenuBarAgentPositionStore.move(
            item: a,
            to: .rightOfItem(target),
            liveItems: [a, target, c],
            environment: env
        )

        XCTAssertTrue(applied)
        XCTAssertTrue(nudged)
        // A is placed between T (100) and C (200).
        XCTAssertEqual(written?["status:A::A"], 150)
        // Other weights are untouched.
        XCTAssertEqual(written?["status:A::T"], 100)
        XCTAssertEqual(written?["status:A::C"], 200)
    }

    func testMoveDefersWhenKeyUnresolved() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::T": 100] }, // no key for A
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )
        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(target),
                liveItems: [a, target],
                environment: env
            )
        )
    }

    func testMoveDefersWhenNoGap() {
        let a = item("A", x: 0)
        let target = item("T", x: 30)
        let c = item("C", x: 60)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:A::A": 50, "status:A::T": 100, "status:A::C": 101] },
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )
        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(target),
                liveItems: [a, target, c],
                environment: env
            )
        )
    }

    func testExperimentalMoveCanTargetAnchoredSystemItem() {
        let a = item("A", x: 0)
        let clock = MenuBarItem.fixture(
            tag: .clock,
            windowID: 90,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let c = item("C", x: 60)

        var written: [String: Int]?
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: {
                [
                    "status:com.test.A::A": 50,
                    "module:Clock": 100,
                    "status:com.test.A::C": 200,
                ]
            },
            writePositions: { written = $0 },
            nudgeAgent: {}
        )

        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(clock),
                liveItems: [a, clock, c],
                environment: env
            )
        )

        XCTAssertTrue(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(clock),
                liveItems: [a, clock, c],
                experimentalSystemItemHiding: true,
                environment: env
            )
        )
        XCTAssertEqual(written?["status:com.test.A::A"], 150)
    }

    func testExperimentalMoveDoesNotTargetSystemUIServerItem() {
        let a = item("A", x: 0)
        let siri = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .systemUIServer, title: "Siri", windowID: 91),
            windowID: 91,
            bounds: CGRect(x: 30, y: 0, width: 24, height: 22)
        )
        let c = item("C", x: 60)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: {
                [
                    "status:com.test.A::A": 50,
                    "status:com.apple.systemuiserver::Siri": 100,
                    "status:com.test.A::C": 200,
                ]
            },
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )

        XCTAssertFalse(
            MenuBarAgentPositionStore.move(
                item: a,
                to: .rightOfItem(siri),
                liveItems: [a, siri, c],
                experimentalSystemItemHiding: true,
                environment: env
            )
        )
    }

    // MARK: - applyOrder (batch)

    func testApplyOrderPermutesExistingWeightsIntoDesiredOrder() {
        // Live order A,B,C (x ascending) with ascending weight axis. Want C,A,B.
        let a = item("A", x: 0)
        let b = item("B", x: 30)
        let c = item("C", x: 60)
        var written: [String: Int]?
        var nudges = 0
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:com.test.A::A": 100, "status:com.test.A::B": 200, "status:com.test.A::C": 300] },
            writePositions: { written = $0 },
            nudgeAgent: { nudges += 1 }
        )

        let changed = MenuBarAgentPositionStore.applyOrder(
            desiredOrder: [c.uniqueIdentifier, a.uniqueIdentifier, b.uniqueIdentifier],
            liveItems: [a, b, c],
            environment: env
        )

        // The segment's own slots {100,200,300} are reassigned in desired order:
        // C leftmost → 100, A → 200, B → 300. One write, one nudge.
        XCTAssertEqual(written?["status:com.test.A::C"], 100)
        XCTAssertEqual(written?["status:com.test.A::A"], 200)
        XCTAssertEqual(written?["status:com.test.A::B"], 300)
        XCTAssertEqual(nudges, 1)
        XCTAssertEqual(Set(changed), [a.uniqueIdentifier, b.uniqueIdentifier, c.uniqueIdentifier])
    }

    func testApplyOrderNoopWhenAlreadyOrdered() {
        let a = item("A", x: 0)
        let b = item("B", x: 30)
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:com.test.A::A": 100, "status:com.test.A::B": 200] },
            writePositions: { _ in XCTFail("should not write") },
            nudgeAgent: { XCTFail("should not nudge") }
        )
        let changed = MenuBarAgentPositionStore.applyOrder(
            desiredOrder: [a.uniqueIdentifier, b.uniqueIdentifier],
            liveItems: [a, b],
            environment: env
        )
        XCTAssertTrue(changed.isEmpty)
    }

    func testApplyOrderHonorsDescendingAxis() {
        // Same desired order, but the live axis descends (leftmost has the
        // largest weight). Slots must be assigned high→low so C still lands left.
        let a = item("A", x: 0)
        let b = item("B", x: 30)
        let c = item("C", x: 60)
        var written: [String: Int]?
        let env = MenuBarAgentPositionStore.Environment(
            readPositions: { ["status:com.test.A::A": 300, "status:com.test.A::B": 200, "status:com.test.A::C": 100] },
            writePositions: { written = $0 },
            nudgeAgent: {}
        )
        _ = MenuBarAgentPositionStore.applyOrder(
            desiredOrder: [c.uniqueIdentifier, a.uniqueIdentifier, b.uniqueIdentifier],
            liveItems: [a, b, c],
            environment: env
        )
        // Descending axis: leftmost desired (C) gets the largest slot (300).
        XCTAssertEqual(written?["status:com.test.A::C"], 300)
        XCTAssertEqual(written?["status:com.test.A::A"], 200)
        XCTAssertEqual(written?["status:com.test.A::B"], 100)
    }

    // MARK: - Helpers

    /// A movable third-party status item under the "A" app at the given x.
    private func item(_ title: String, x: CGFloat) -> MenuBarItem {
        MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.test.A", title: title),
            windowID: CGWindowID(abs(x.hashValue % 100_000) + 10),
            bounds: CGRect(x: x, y: 0, width: 24, height: 22)
        )
    }
}
