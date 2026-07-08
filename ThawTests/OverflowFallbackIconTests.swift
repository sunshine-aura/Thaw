//
//  OverflowFallbackIconTests.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
@testable import Thaw
import XCTest

@MainActor
final class OverflowFallbackIconTests: XCTestCase {
    func testSupportsMissingCaptureFallbackOnlyForConcealedSections() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Concealed-section app-icon fallback is macOS 27-specific")
        }

        XCTAssertTrue(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .hidden))
        XCTAssertTrue(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .alwaysHidden))
        XCTAssertFalse(OverflowFallbackIcon.supportsMissingCaptureFallback(for: .visible))
        XCTAssertFalse(OverflowFallbackIcon.supportsMissingCaptureFallback(for: nil))
    }

    func testShouldPreferAppIconWhenCaptureMissingWithoutOverflowToggle() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Concealed-section app-icon fallback is macOS 27-specific")
        }

        let appState = AppState()
        appState.settings.advanced.enableExperimentalOverflowPrevention = false

        XCTAssertTrue(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .alwaysHidden,
                appState: appState,
                cachedImage: nil
            )
        )
        XCTAssertFalse(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .alwaysHidden,
                appState: appState,
                cachedImage: NSImage(size: NSSize(width: 16, height: 16))
            )
        )
    }

    func testShouldPreferAppIconAlwaysWhenOverflowToggleEnabled() throws {
        guard #available(macOS 27, *) else {
            throw XCTSkip("Concealed-section app-icon fallback is macOS 27-specific")
        }

        let appState = AppState()
        appState.settings.advanced.enableExperimentalOverflowPrevention = true
        let cached = NSImage(size: NSSize(width: 16, height: 16))

        XCTAssertTrue(
            OverflowFallbackIcon.shouldPreferAppIcon(
                for: .hidden,
                appState: appState,
                cachedImage: cached
            )
        )
    }
}
