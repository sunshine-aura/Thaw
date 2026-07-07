//
//  ManagedAgentRestarter.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Cocoa

enum ManagedAgentRestarter {
    struct RunningApplication {
        let bundleIdentifier: String?
        let processIdentifier: pid_t
    }

    static func restart(bundleID: String, signal: Int32 = SIGTERM) {
        restart(
            bundleID: bundleID,
            signal: signal,
            runningApplications: NSWorkspace.shared.runningApplications.map {
                RunningApplication(
                    bundleIdentifier: $0.bundleIdentifier,
                    processIdentifier: $0.processIdentifier
                )
            },
            sendSignal: kill
        )
    }

    static func restart(
        bundleID: String,
        signal: Int32 = SIGTERM,
        runningApplications: [RunningApplication],
        sendSignal: (pid_t, Int32) -> Int32
    ) {
        for app in runningApplications where app.bundleIdentifier == bundleID {
            _ = sendSignal(app.processIdentifier, signal)
        }
    }
}
