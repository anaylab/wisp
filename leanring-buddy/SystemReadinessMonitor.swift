//
//  SystemReadinessMonitor.swift
//  leanring-buddy
//
//  Whether the Mac is in a state where unattended work can succeed: awake for long enough that
//  the network, connected apps and the model have come back, and online. Scheduled automations
//  and buddy jobs read it so a run that comes due right after wake, or while the Wi-Fi is down,
//  waits instead of failing ("couldn't reach Gmail") and counting toward a pause.
//
//  Sleep/wake comes from NSWorkspace's notifications, connectivity from NWPathMonitor. Nothing
//  here prompts or sends anything.
//

import AppKit
import Combine
import Network

@MainActor
final class SystemReadinessMonitor: ObservableObject {
    static let shared = SystemReadinessMonitor()

    /// How long after wake unattended work waits. Wi-Fi typically rejoins in 5–20s; this leaves
    /// room for a VPN, Ollama reloading the model, and MCP servers reconnecting.
    static let settleSecondsAfterWake: TimeInterval = 45

    @Published private(set) var isAsleep = false
    @Published private(set) var lastWakeDate: Date?
    /// True until the path monitor says otherwise, so a monitor that never started (tests,
    /// previews) never holds anything back.
    @Published private(set) var isNetworkReachable = true

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "com.wisp.system-readiness.path")
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hasStarted = false

    private init() {}

    /// Idempotent; called once from `applicationDidFinishLaunching`.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAsleep = true }
        })
        workspaceObservers.append(workspaceNotificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                self?.lastWakeDate = Date()
            }
        })

        pathMonitor.pathUpdateHandler = { [weak self] path in
            // `.satisfied` means a route exists; it can't prove a captive portal lets traffic
            // through, but it is the same signal the system uses for "you're online".
            let isReachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self, self.isNetworkReachable != isReachable else { return }
                self.isNetworkReachable = isReachable
                print("🌐 Wisp: network \(isReachable ? "reachable" : "unreachable")")
            }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// Awake, and at least `settleSecondsAfterWake` past the last wake.
    func isSettledAfterWake(now: Date = Date()) -> Bool {
        SystemReadinessPolicy.isSettledAfterWake(
            isAsleep: isAsleep,
            lastWakeDate: lastWakeDate,
            now: now,
            settleSeconds: Self.settleSecondsAfterWake
        )
    }
}

/// The pure part, so the rule can be tested without sleeping a Mac.
nonisolated enum SystemReadinessPolicy {
    static func isSettledAfterWake(isAsleep: Bool, lastWakeDate: Date?, now: Date, settleSeconds: TimeInterval) -> Bool {
        guard !isAsleep else { return false }
        guard let lastWakeDate else { return true }
        return now.timeIntervalSince(lastWakeDate) >= settleSeconds
    }
}
