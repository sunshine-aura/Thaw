//
//  TrailingItemPreferredPositionsKeysTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

@testable import Thaw
import XCTest

/// Canonical suite for `TrailingItemPreferredPositions` key resolution. Both
/// position stores (``TrailingItemPositionStore``, ``MenuBarAgentPositionStore``)
/// and ``SimpleItemHider`` delegate here, so these cases cover every consumer.
@available(macOS 27, *)
@MainActor
final class TrailingItemPreferredPositionsKeysTests: XCTestCase {
    // MARK: - naiveKey

    func testNaiveKeyUsesBundleIDAndTitle() {
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "com.foo.Bar", title: "Item-0"), windowID: 1)
        XCTAssertEqual(TrailingItemPreferredPositionsKeys.naiveKey(for: item), "status:com.foo.Bar::Item-0")
    }

    // MARK: - midpointPosition

    func testMidpointReturnsValueBetweenNeighbors() {
        XCTAssertEqual(TrailingItemPreferredPositionsKeys.midpointPosition(between: 100, and: 200), 150)
    }

    func testMidpointIsOrderAgnostic() {
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.midpointPosition(between: 200, and: 100),
            TrailingItemPreferredPositionsKeys.midpointPosition(between: 100, and: 200)
        )
    }

    func testMidpointNilWhenNoIntegerGap() {
        XCTAssertNil(TrailingItemPreferredPositionsKeys.midpointPosition(between: 100, and: 101))
        XCTAssertNil(TrailingItemPreferredPositionsKeys.midpointPosition(between: 100, and: 100))
    }

    // MARK: - resolveKey (title tiers)

    func testResolveModuleKey() {
        let item = MenuBarItem.fixture(
            tag: MenuBarItemTag(namespace: .menuBarAgent, title: "WiFi"),
            windowID: 1
        )
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(for: item, existingKeys: ["module:WiFi", "module:Clock"]),
            "module:WiFi"
        )
    }

    func testResolveStatusKeyByBundleIDForm() {
        // The exact bundle-ID key must win over the ambiguous suffix match:
        // many apps share the generic "Item-0" title.
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "notion.id", title: "Item-0"), windowID: 2)
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: item,
                existingKeys: [
                    "status:notion.id::Item-0",
                    "status:cc.ffitch.shottr::Item-0",
                    "status:com.anthropic.claudefordesktop::Item-0",
                ]
            ),
            "status:notion.id::Item-0"
        )
    }

    func testResolveStatusKeyBySuffix() {
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "com.foo.Bar", title: "Item-0"), windowID: 2)
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: item,
                existingKeys: ["status:Bar::Item-0", "status:Other::Item-9"]
            ),
            "status:Bar::Item-0"
        )
    }

    func testResolveReturnsNilWhenAbsent() {
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "com.foo.Bar", title: "Ghost"), windowID: 3)
        XCTAssertNil(
            TrailingItemPreferredPositionsKeys.resolveKey(for: item, existingKeys: ["status:Bar::Item-0"])
        )
    }

    func testTitleTierKeyMatchesResolveKeyWithoutPositions() {
        // titleTierKey is exactly resolveKey minus the positional fallback.
        let item = MenuBarItem.fixture(tag: .appItem(bundleID: "notion.id", title: "Item-0"), windowID: 4)
        let keys = ["status:notion.id::Item-0"]
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.titleTierKey(for: item, existingKeys: keys),
            TrailingItemPreferredPositionsKeys.resolveKey(for: item, existingKeys: keys)
        )
    }

    // MARK: - resolvePositionalKey (dynamic-title fallback)

    func testResolvePositionalKeyPairsSiblingsByXAndWeightWhenTitlesNeverMatch() {
        // iStat-style family: three siblings whose live titles never match the
        // stable internal identifiers MenuBarAgent stores them under.
        let cpu = istat("CPU 9%", x: 0, windowID: 10)
        let mem = istat("MEM 51%", x: 50, windowID: 11)
        let net = istat("12.3 KB/s", x: 100, windowID: 12)
        let positions = [
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 100,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.memory": 200,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.network": 300,
        ]
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: cpu, existingKeys: Array(positions.keys), positions: positions, liveItems: [cpu, mem, net]
            ),
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu"
        )
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: net, existingKeys: Array(positions.keys), positions: positions, liveItems: [cpu, mem, net]
            ),
            "status:com.bjango.istatmenus::com.bjango.istatmenus.network"
        )
    }

    func testResolvePositionalKeyInfersDescendingAxisFromUnrelatedReferenceItems() {
        // This bar's weight axis descends left-to-right. Two unrelated,
        // title-resolvable reference items carry the only evidence: the left one
        // has the larger weight. Resolution must read the axis from them rather
        // than assuming ascending, or it pairs every sibling backwards.
        let referenceLeft = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Left", title: "Marker"), windowID: 20, bounds: rect(x: 0)
        )
        let referenceRight = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Right", title: "Marker"), windowID: 21, bounds: rect(x: 200)
        )
        let cpu = istat("CPU 9%", x: 50, windowID: 10)
        let mem = istat("MEM 51%", x: 100, windowID: 11)
        let net = istat("12.3 KB/s", x: 150, windowID: 12)
        let positions = [
            "status:com.foo.Left::Marker": 300,
            "status:com.foo.Right::Marker": 100,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 50,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.memory": 30,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.network": 10,
        ]
        let liveItems = [referenceLeft, cpu, mem, net, referenceRight]
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: cpu, existingKeys: Array(positions.keys), positions: positions, liveItems: liveItems
            ),
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu"
        )
        XCTAssertEqual(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: net, existingKeys: Array(positions.keys), positions: positions, liveItems: liveItems
            ),
            "status:com.bjango.istatmenus::com.bjango.istatmenus.network"
        )
    }

    func testResolvePositionalKeyNilWhenFamilyCountMismatch() {
        let cpu = istat("CPU 9%", x: 0, windowID: 10)
        let mem = istat("MEM 51%", x: 50, windowID: 11)
        let net = istat("12.3 KB/s", x: 100, windowID: 12)
        let positions = [
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 100,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.memory": 200,
        ]
        XCTAssertNil(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: cpu, existingKeys: Array(positions.keys), positions: positions, liveItems: [cpu, mem, net]
            )
        )
    }

    func testResolvePositionalKeyNilWithoutSiblings() {
        let lone = istat("CPU 9%", x: 0, windowID: 10)
        XCTAssertNil(
            TrailingItemPreferredPositionsKeys.resolveKey(
                for: lone,
                existingKeys: ["status:com.bjango.istatmenus::com.bjango.istatmenus.cpu"],
                positions: ["status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 100],
                liveItems: [lone]
            )
        )
    }

    // MARK: - Regression: axis-reversal parity across both store facades

    func testBothStoreFacadesResolveSamePositionalKeyUnderReversedAxis() {
        // The trailing store used to sort family keys ascending-only, so under a
        // reversed axis it paired siblings backwards while the agent store paired
        // them correctly. Both now delegate to the shared axis-aware resolver, so
        // they must agree. This is the regression guard for that divergence.
        let referenceLeft = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Left", title: "Marker"), windowID: 20, bounds: rect(x: 0)
        )
        let referenceRight = MenuBarItem.fixture(
            tag: .appItem(bundleID: "com.foo.Right", title: "Marker"), windowID: 21, bounds: rect(x: 200)
        )
        let cpu = istat("CPU 9%", x: 50, windowID: 10)
        let mem = istat("MEM 51%", x: 100, windowID: 11)
        let net = istat("12.3 KB/s", x: 150, windowID: 12)
        // Descending axis: leftmost reference carries the larger weight.
        let positions = [
            "status:com.foo.Left::Marker": 300,
            "status:com.foo.Right::Marker": 100,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 50,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.memory": 30,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.network": 10,
        ]
        let liveItems = [referenceLeft, cpu, mem, net, referenceRight]
        let keys = Array(positions.keys)

        for probe in [cpu, mem, net] {
            let trailing = TrailingItemPositionStore.resolvePositionalKey(
                for: probe, existingKeys: keys, positions: positions, allItems: liveItems
            )
            let agent = MenuBarAgentPositionStore.resolveKey(
                for: probe, existingKeys: keys, positions: positions, liveItems: liveItems
            )
            XCTAssertEqual(trailing, agent, "facades disagreed for \(probe.tag.title)")
        }
        // And the leftmost live sibling maps to the largest-weight key (cpu=50).
        XCTAssertEqual(
            TrailingItemPositionStore.resolvePositionalKey(
                for: cpu, existingKeys: keys, positions: positions, allItems: liveItems
            ),
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu"
        )
    }

    // MARK: - Regression: naive key diverges from resolved key for dynamic titles

    func testNaiveKeyDivergesFromResolvedKeyForDynamicTitleApp() {
        // The SimpleItemHider bug class: for an iStat-style item the naive
        // status:<bundle>::<title> key is NOT the key MenuBarAgent stored, so
        // any comparison against the naive key silently misses.
        let cpu = istat("CPU 9%", x: 0, windowID: 10)
        let mem = istat("MEM 51%", x: 50, windowID: 11)
        let positions = [
            "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu": 100,
            "status:com.bjango.istatmenus::com.bjango.istatmenus.memory": 200,
        ]
        let resolved = TrailingItemPreferredPositionsKeys.resolveKey(
            for: cpu, existingKeys: Array(positions.keys), positions: positions, liveItems: [cpu, mem]
        )
        let naive = TrailingItemPreferredPositionsKeys.naiveKey(for: cpu)
        XCTAssertEqual(resolved, "status:com.bjango.istatmenus::com.bjango.istatmenus.cpu")
        XCTAssertEqual(naive, "status:com.bjango.istatmenus::CPU 9%")
        XCTAssertNotEqual(resolved, naive)
    }

    // MARK: - Helpers

    private func rect(x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 40, height: 22)
    }

    /// An iStat Menus sibling item under the shared bundle at the given x.
    private func istat(_ title: String, x: CGFloat, windowID: CGWindowID) -> MenuBarItem {
        MenuBarItem.fixture(tag: .appItem(bundleID: "com.bjango.istatmenus", title: title), windowID: windowID, bounds: rect(x: x))
    }
}
