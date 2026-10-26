//
//  FocusItemController.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// Stand-in for macOS's Focus menu-bar item while the bar is collapsed. Native
// hiding on macOS 27 always hides the real one: no system item identifier or
// bundle keeps it visible (measured on 27.0.1). Hidden Bar's own items are
// always allowed, so this one stays.
//
// macOS has no public Focus API for other apps, so:
// - Reading: the modes and the active one come from macOS's Focus database in
//   ~/Library/DoNotDisturb/DB, which needs Full Disk Access.
// - Switching: each mode runs a Shortcut the user creates once, named
//   "HB Focus <mode name>" ("HB Focus Off" ends the active Focus), built
//   around the "Set Focus" action.
final class FocusItemController: NSObject, NSMenuDelegate {
    struct Mode: Equatable {
        let identifier: String
        let name: String
        let symbolName: String
    }

    static let shortcutPrefix = "HB Focus "
    static let offShortcutName = "HB Focus Off"

    private static let databaseURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB")

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var refreshTimer: Timer?

    private var modes: [Mode] = []
    private var activeModeIdentifier: String?
    private var canReadDatabase = true

    override init() {
        super.init()
        item.autosaveName = "hiddenbar_focus"
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        // ponytail: isVisible = false lets macOS forget a ⌘-dragged position; a
        // zero length would keep it but leaves a gap in the expanded bar.
        item.isVisible = false
    }

    deinit {
        refreshTimer?.invalidate()
        NSStatusBar.system.removeStatusItem(item)
    }

    // Shown only while collapsed: expanded, the real Focus item is back.
    func setVisible(_ visible: Bool) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        item.isVisible = visible
        guard visible else { return }
        refresh()
        // ponytail: polls a small file every 2s while collapsed; a file-system
        // watcher if this ever shows up in a profile.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        do {
            modes = try Self.readModes()
            activeModeIdentifier = try Self.readActiveModeIdentifier()
            canReadDatabase = true
        } catch {
            canReadDatabase = false
            activeModeIdentifier = nil
        }
        updateButton()
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let active = modes.first { $0.identifier == activeModeIdentifier }
        let symbolName = active?.symbolName ?? "moon"
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: active?.name ?? "Focus".localized)
            ?? NSImage(systemSymbolName: "moon", accessibilityDescription: "Focus".localized)
        // Dimmed while no Focus is on, so it reads as "off" like a menu toggle.
        button.appearsDisabled = active == nil
        button.toolTip = active?.name ?? "Focus".localized
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refresh()
        menu.removeAllItems()

        guard canReadDatabase else {
            menu.addItem(actionItem("Allow Full Disk Access to Show Focus…".localized, #selector(openFullDiskAccessSettings)))
            menu.addItem(.separator())
            menu.addItem(actionItem("Focus Settings…".localized, #selector(openFocusSettings)))
            return
        }

        for mode in modes {
            let modeItem = actionItem(mode.name, #selector(selectMode(_:)))
            modeItem.representedObject = mode.name
            modeItem.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.name)
            modeItem.state = mode.identifier == activeModeIdentifier ? .on : .off
            menu.addItem(modeItem)
        }
        if activeModeIdentifier != nil {
            menu.addItem(.separator())
            menu.addItem(actionItem("Turn Off Focus".localized, #selector(turnOffFocus)))
        }
        menu.addItem(.separator())
        menu.addItem(actionItem("Focus Settings…".localized, #selector(openFocusSettings)))
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        // Picking the active mode again turns it off, like the real menu.
        if sender.state == .on {
            runShortcut(named: Self.offShortcutName)
        } else {
            runShortcut(named: Self.shortcutPrefix + name)
        }
    }

    @objc private func turnOffFocus() {
        runShortcut(named: Self.offShortcutName)
    }

    @objc private func openFocusSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
    }

    @objc private func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    // MARK: - Shortcuts

    private func runShortcut(named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let succeeded = finished.terminationStatus == 0
            DispatchQueue.main.async {
                if succeeded {
                    self?.refresh()
                } else {
                    self?.showMissingShortcutAlert(named: name)
                }
            }
        }
        do {
            try process.run()
        } catch {
            showMissingShortcutAlert(named: name)
        }
    }

    private func showMissingShortcutAlert(named name: String) {
        let alert = NSAlert()
        alert.messageText = String(format: "The Shortcut \"%@\" could not be run.".localized, name)
        alert.informativeText = String(format: "Hidden Bar changes Focus through Shortcuts. In the Shortcuts app, create a shortcut named \"%@\" with the \"Set Focus\" action.".localized, name)
        alert.addButton(withTitle: "Open Shortcuts".localized)
        alert.addButton(withTitle: "Cancel".localized)
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Shortcuts.app"))
        }
    }

    // MARK: - Focus database

    // The undocumented format, as written by macOS 12 through 27:
    // ModeConfigurations.json: { data: [ { modeConfigurations: { <id>: { mode: { name, modeIdentifier, symbolImageName } } } } ] }
    // Assertions.json:         { data: [ { storeAssertionRecords: [ { assertionDetails: { assertionDetailsModeIdentifier }, assertionStartDateTimestamp } ] } ] }
    static func readModes(from directory: URL = databaseURL) throws -> [Mode] {
        let store = try firstDataEntry(of: directory.appendingPathComponent("ModeConfigurations.json"))
        let configurations = store["modeConfigurations"] as? [String: Any] ?? [:]
        return configurations.values.compactMap { value -> Mode? in
            guard let mode = (value as? [String: Any])?["mode"] as? [String: Any],
                  let identifier = mode["modeIdentifier"] as? String,
                  let name = mode["name"] as? String else { return nil }
            return Mode(identifier: identifier,
                        name: name,
                        symbolName: symbolName(of: mode, identifier: identifier))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Newer modes draw a symbol descriptor rather than symbolImageName: Reduce
    // Interruptions keeps "moon.fill" there for old clients but shows "_gm",
    // which the system symbol catalog resolves to the Apple Intelligence glyph.
    static let reduceInterruptionsIdentifier = "com.apple.focus.reduce-interruptions"

    private static func symbolName(of mode: [String: Any], identifier: String) -> String {
        if let descriptor = mode["symbolDescriptor"] as? [String: Any],
           let imageName = descriptor["imageName"] as? String {
            return imageName
        }
        if identifier == reduceInterruptionsIdentifier {
            return "_gm"
        }
        return mode["symbolImageName"] as? String ?? "moon.fill"
    }

    // ponytail: Focus turned on by a schedule or automation may not write an
    // assertion and then reads as off; parse the trigger records if that matters.
    static func readActiveModeIdentifier(from directory: URL = databaseURL) throws -> String? {
        let store = try firstDataEntry(of: directory.appendingPathComponent("Assertions.json"))
        let records = store["storeAssertionRecords"] as? [[String: Any]] ?? []
        let latest = records.max {
            ($0["assertionStartDateTimestamp"] as? Double ?? 0) < ($1["assertionStartDateTimestamp"] as? Double ?? 0)
        }
        let details = latest?["assertionDetails"] as? [String: Any]
        return details?["assertionDetailsModeIdentifier"] as? String
    }

    private static func firstDataEntry(of url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (json?["data"] as? [[String: Any]])?.first ?? [:]
    }
}
