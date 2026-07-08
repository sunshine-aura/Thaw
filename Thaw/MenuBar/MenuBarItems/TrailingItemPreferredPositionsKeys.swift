//
//  TrailingItemPreferredPositionsKeys.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

// MARK: - TrailingItemPreferredPositionsKeys

/// Canonical, side-effect-free resolution of `TrailingItemPreferredPositions`
/// keys — the single source of truth shared by every subsystem that reads or
/// writes `com.apple.MenuBarAgent`'s layout preference on macOS 27.
///
/// macOS 27 records the menu bar's arrangement in a single preference value:
///
///     com.apple.MenuBarAgent → TrailingItemPreferredPositions : { key → Int }
///
/// where each key is one of three shapes:
///
///   * `module:<Name>`          — Apple Control Center modules (`module:WiFi`).
///   * `status:<bundleID>::<ItemID>` — the common third-party form, where
///     `<bundleID>` is the owning app's bundle identifier (== the item's
///     namespace) and `<ItemID>` == Thaw's `tag.title` (both read the AX
///     identifier), e.g. `status:notion.id::Item-0`.
///   * `status:<AppDisplayName>::<ItemID>` — the minority form used by apps
///     that register a display name (e.g. `status:iStat Menus Menubar::…`).
///
/// This type owns the algorithm; the position stores
/// (``TrailingItemPositionStore``, ``MenuBarAgentPositionStore``) and
/// ``SimpleItemHider`` delegate here so a live item always resolves to the same
/// key regardless of which pipeline is asking. Callers keep their own
/// preference I/O policies — only key resolution and the shared weight math
/// live here.
@MainActor
enum TrailingItemPreferredPositionsKeys {
    /// The naive `status:<bundleID>::<title>` key built directly from the item's
    /// current AX title. Correct for stable-title apps, but wrong for apps like
    /// iStat Menus that rewrite their title every second while registering under
    /// a stable internal identifier — prefer ``resolveKey`` for anything that
    /// must match what MenuBarAgent actually stored.
    static func naiveKey(for item: MenuBarItem) -> String {
        "status:\(item.tag.namespace)::\(item.tag.title)"
    }

    /// Resolves a live item to its existing key in the positions dictionary,
    /// trying the title-based tiers first and falling back to the positional
    /// heuristic for dynamic-title apps.
    ///
    /// `positions` and `liveItems` are only consulted by the positional
    /// fallback; omit them to use the title-only tiers (e.g. from tests).
    static func resolveKey(
        for item: MenuBarItem,
        existingKeys: [String],
        positions: [String: Int] = [:],
        liveItems: [MenuBarItem] = []
    ) -> String? {
        if let key = titleTierKey(for: item, existingKeys: existingKeys) {
            return key
        }

        // Every title-based tier failed outright. Apps like iStat Menus rewrite
        // their item's AX title every second ("CPU 10%" → "CPU 9%" → …), but
        // register their MenuBarAgent key under a stable internal identifier
        // instead (e.g. "com.bjango.istatmenus.cpu") that never appears in the
        // live title, so no title-based tier can ever match it. When the item
        // has sibling items from the same owning app, the bar's left-to-right
        // order is the last stable signal: pair the Nth sibling by X position
        // with the Nth sibling key by weight.
        return resolvePositionalKey(
            for: item,
            existingKeys: existingKeys,
            positions: positions,
            liveItems: liveItems
        )
    }

    /// Title-based key resolution — the tiers ``resolveKey`` tries before
    /// falling back to ``resolvePositionalKey``. Factored out so
    /// ``resolvePositionalKey`` can also use it, on *other* live items, to infer
    /// the store's weight axis without recursing into itself.
    ///
    /// Resolution order is module → exact bundle-ID form → display-name suffix.
    /// The bundle-ID form is exact, so it is preferred over the suffix match,
    /// which for generic `Item-0` titles has dozens of candidates that only the
    /// owning app's display name disambiguates.
    static func titleTierKey(for item: MenuBarItem, existingKeys: [String]) -> String? {
        let title = item.tag.title
        guard !title.isEmpty else { return nil }

        // Apple modules hosted by MenuBarAgent.
        if item.tag.namespace.isMenuBarHostingNamespace {
            let moduleKey = SystemMenuBarModuleCatalog.trailingPositionsModuleKey(forTitle: title)
            if existingKeys.contains(moduleKey) {
                return moduleKey
            }
        }

        // Exact bundle-ID form: status:<namespace>::<title>.
        let bundleKey = "status:\(item.tag.namespace.description)::\(title)"
        if existingKeys.contains(bundleKey) {
            return bundleKey
        }

        // Display-name form, disambiguated by the owning app's display name when
        // the item title alone (e.g. "Item-0") matches several apps.
        let suffix = "::\(title)"
        let candidates = existingKeys.filter { $0.hasPrefix("status:") && $0.hasSuffix(suffix) }
        if candidates.count == 1 {
            return candidates[0]
        }
        if candidates.count > 1 {
            let appNames = candidateAppNames(for: item)
            if let match = candidates.first(where: { key in
                let app = key.dropFirst("status:".count).dropLast(suffix.count)
                return appNames.contains(String(app))
            }) {
                return match
            }
        }
        return nil
    }

    /// Last-resort key resolution for items whose title never matches their
    /// store key. Requires the owning app's family of live items and the
    /// family's keys in the store to be the same size — an exact count match is
    /// the only way to pair them without guessing at which sibling is which. The
    /// weight axis (does smaller weight mean further left, or further right?) is
    /// inferred from other live items elsewhere in the bar that resolve
    /// unambiguously by title — the axis is one global sort key shared by the
    /// whole bar, so any such reference pair determines it — rather than assumed
    /// to be ascending. Without a reference pair this still defaults to
    /// ascending (the observed system default, e.g. `module:Clock` = 0 at the
    /// leading edge); the caller verifies the resulting live order and falls
    /// back to synthetic drag when it doesn't hold, so a remaining wrong guess
    /// is self-correcting.
    static func resolvePositionalKey(
        for item: MenuBarItem,
        existingKeys: [String],
        positions: [String: Int],
        liveItems: [MenuBarItem]
    ) -> String? {
        let family = MenuBarItem.sortByLeadingEdge(
            liveItems.filter { !$0.isSystemClone && $0.tag.namespace == item.tag.namespace }
        )
        guard
            family.count > 1,
            let itemIndex = family.firstIndex(where: { $0.tag.matchesIgnoringWindowID(item.tag) })
        else {
            return nil
        }

        var familyKeys = existingKeys.filter { $0.hasPrefix("status:\(item.tag.namespace.description)::") }
        if familyKeys.count != family.count {
            // Some apps register under a display name instead of their bundle
            // ID; retry with that prefix before giving up.
            let displayPrefixes = candidateAppNames(for: item).map { "status:\($0)::" }
            familyKeys = existingKeys.filter { key in displayPrefixes.contains { key.hasPrefix($0) } }
        }
        guard familyKeys.count == family.count else { return nil }

        let referencePairs: [(item: MenuBarItem, weight: Int)] = liveItems.compactMap { candidate in
            guard
                let key = titleTierKey(for: candidate, existingKeys: existingKeys),
                let weight = positions[key]
            else { return nil }
            return (candidate, weight)
        }
        let ascending = ascendingAxis(for: referencePairs)

        let orderedKeys = familyKeys.sorted { key1, key2 in
            let weight1 = positions[key1] ?? 0
            let weight2 = positions[key2] ?? 0
            return ascending ? weight1 < weight2 : weight1 > weight2
        }
        return orderedKeys[itemIndex]
    }

    /// Whether a weight axis ascends left-to-right (smaller weight = further
    /// left), read from the given items' current geometry. A flat or
    /// single-extent input defaults to ascending (the observed system default,
    /// e.g. Clock = 0 at the leading edge). The axis is a single global sort key
    /// shared by the whole bar, so this is valid whether the pairs come from one
    /// reorder segment or from unrelated items scattered across the bar.
    static func ascendingAxis(
        for pairs: [(item: MenuBarItem, weight: Int)]
    ) -> Bool {
        let byPosition = pairs.sorted { $0.item.bounds.midX < $1.item.bounds.midX }
        guard let leftmost = byPosition.first, let rightmost = byPosition.last,
              leftmost.weight != rightmost.weight
        else { return true }
        return leftmost.weight < rightmost.weight
    }

    /// Returns a weight that sorts strictly between `anchorValue` and
    /// `neighborValue`, or nil when no integer lies between them. Order-agnostic:
    /// the midpoint sorts between the two regardless of which is larger, so the
    /// caller never has to know whether the weight axis grows left or right.
    static func midpointPosition(between anchorValue: Int, and neighborValue: Int) -> Int? {
        let lo = min(anchorValue, neighborValue)
        let hi = max(anchorValue, neighborValue)
        guard hi - lo >= 2 else { return nil }
        return lo + (hi - lo) / 2
    }

    /// Display-name candidates MenuBarAgent might use for the item's owning app.
    static func candidateAppNames(for item: MenuBarItem) -> Set<String> {
        var names = Set<String>()
        if let localized = item.sourceApplication?.localizedName {
            names.insert(localized)
        }
        names.insert(item.displayName)
        return names
    }
}
