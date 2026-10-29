//
//  TimerItemController.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// Stand-in for the Clock app's timer countdown in the menu bar while the bar is
// collapsed. Like Focus, native hiding on macOS 27 always hides the real one: no
// system item identifier (0-4095) or bundle (com.apple.clock, mobiletimerd,
// MenuBarAgent...) keeps it visible (measured on 27.0.1).
//
// The timers come from mobiletimerd's preferences, which macOS keeps current and
// any non-sandboxed app can read. Clicking opens the Clock app.
final class TimerItemController: NSObject {
    struct ActiveTimer: Equatable {
        let remaining: TimeInterval
        let isPaused: Bool
    }

    private static let domain = "com.apple.mobiletimerd" as CFString
    private static let runningState = 3
    private static let pausedState = 2

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?

    override init() {
        super.init()
        item.autosaveName = "hiddenbar_timer"
        item.button?.target = self
        item.button?.action = #selector(openClock)
        item.button?.imagePosition = .imageLeading
        item.button?.image = NSImage(systemSymbolName: "timer", accessibilityDescription: "Timer".localized)
        // Same as the Focus stand-in: isVisible = false forgets a ⌘-dragged position.
        item.isVisible = false
    }

    deinit {
        refreshTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    // Collapsed: ticks every second and shows itself only while a timer runs or
    // is paused. Expanded: the real countdown is back.
    func setVisible(_ visible: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard visible else {
            item.isVisible = false
            return
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        CFPreferencesAppSynchronize(Self.domain)
        let timers = CFPreferencesCopyAppValue("MTTimers" as CFString, Self.domain) as? [String: Any]
        let list = timers?["MTTimers"] as? [[String: Any]] ?? []
        guard let active = Self.activeTimer(in: list, now: Date()) else {
            item.isVisible = false
            return
        }
        item.isVisible = true
        item.button?.title = Self.format(active.remaining)
        item.button?.appearsDisabled = active.isPaused
    }

    @objc private func openClock() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Clock.app"))
    }

    // The undocumented format, as written by macOS 27:
    // MTTimers: { MTTimers: [ { $MTTimer: { MTTimerState, MTTimerFireTime: { $MTTimerDate: { MTTimerTimeDate } }
    //                                                                     | { $MTTimerTimeInterval: { MTTimerTimeInterval } } } } ] }
    // Running timers carry the fire date, paused ones the time left.
    // ponytail: with several timers the soonest wins; the real item shows the same.
    static func activeTimer(in timers: [[String: Any]], now: Date) -> ActiveTimer? {
        return timers.compactMap { entry -> ActiveTimer? in
            guard let timer = entry["$MTTimer"] as? [String: Any],
                  let state = timer["MTTimerState"] as? Int,
                  let fireTime = timer["MTTimerFireTime"] as? [String: Any] else { return nil }
            if state == runningState,
               let date = (fireTime["$MTTimerDate"] as? [String: Any])?["MTTimerTimeDate"] as? Date,
               date > now {
                return ActiveTimer(remaining: date.timeIntervalSince(now), isPaused: false)
            }
            if state == pausedState,
               let interval = (fireTime["$MTTimerTimeInterval"] as? [String: Any])?["MTTimerTimeInterval"] as? Double {
                return ActiveTimer(remaining: interval, isPaused: true)
            }
            return nil
        }.min { $0.remaining < $1.remaining }
    }

    // "4:05", "25:22", "1:02:03", like the real item.
    static func format(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        let (hours, minutes) = (seconds / 3600, seconds / 60 % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%d:%02d", minutes, seconds % 60)
    }
}
