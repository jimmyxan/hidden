//
//  PerAppSwitchEngine.swift
//  Hidden Bar
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit

// macOS 27 hiding that keeps the real Focus and Clock timer. The native engine's
// restriction hides them whatever it allows, so this backend uses the per-app
// "Allow in the Menu Bar" switch of System Settings instead: no restriction is
// involved, and Apple's own items are never in the list it flips.
//
// NativeVisibilityEngine keeps doing the layout work (sections, always-hidden
// separator, activate-before-release); only the thing that hides is swapped, by
// handing it PerAppSwitchVisibility. MacOS27Engine picks that or the plain
// restriction as the fallback.

// MARK: - The switches

protocol AppSwitchStoring: AnyObject {
    // The list can be read and decoded (access granted, format understood).
    var isAvailable: Bool { get }
    // Bundles whose switch is on, or nil when the list cannot be read.
    func allowedBundles() -> Set<String>?
    // Flips the switches in one write. False when nothing was written.
    func setAllowed(_ changes: [String: Bool]) -> Bool
    // Asks the user to pick the list file. True when access was granted.
    func requestAccess() -> Bool
}

// Control Center's app list lives in a restricted app group. The user picks the
// plist once in an open panel (a user action, it cannot be scripted); the bookmark
// then gives this process read/write. Writes go through CFPreferences with the
// file as domain: a direct file write is ignored by MenuBarAgent (measured 27.2).
final class ControlCenterAppList: AppSwitchStoring {
    static let shared = ControlCenterAppList()

    static let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist")

    private static let key = "trackedApplications" as CFString
    private let bookmarkKey = "ControlCenterAppListBookmark"
    private let defaults: UserDefaults
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isAvailable: Bool {
        return allowedBundles() != nil
    }

    func allowedBundles() -> Set<String>? {
        guard let entries = readEntries() else { return nil }
        return Set(entries.compactMap { Self.bundle(of: $0).flatMap { ($0.1["isAllowed"] as? Bool) == true ? $0.0 : nil } })
    }

    func setAllowed(_ changes: [String: Bool]) -> Bool {
        guard var entries = readEntries(), let domain = domain else { return false }
        var changed = false
        for (index, entry) in entries.enumerated() {
            guard let (bundle, dict) = Self.bundle(of: entry), let wanted = changes[bundle],
                  dict["isAllowed"] as? Bool != wanted else { continue }
            var updated = dict
            updated["isAllowed"] = wanted
            entries[index] = updated
            changed = true
        }
        guard changed else { return true }
        guard let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return false }
        CFPreferencesSetValue(Self.key, data as CFData, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    func requestAccess() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.fileURL.deletingLastPathComponent()
        panel.title = "Grant Access to Control Center's App List".localized
        panel.message = "Select “group.com.apple.controlcenter.plist” to let Hidden Bar hide apps the way System Settings does. Hidden Bar is granted access to this one file only.".localized
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let picked = panel.url,
              picked.standardizedFileURL.path == Self.fileURL.standardizedFileURL.path else { return false }
        store(picked)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        return activate() != nil
    }

    // MARK: Bookmark

    private var domain: CFString? {
        return activate().map { String($0.path.dropLast(".plist".count)) as CFString }
    }

    private func activate() -> URL? {
        if let scopedURL = scopedURL { return scopedURL }
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale),
              url.startAccessingSecurityScopedResource() else {
            defaults.removeObject(forKey: bookmarkKey)
            return nil
        }
        scopedURL = url
        if isStale { store(url) }
        return url
    }

    private func store(_ url: URL) {
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: bookmarkKey)
        }
    }

    // MARK: Format
    // `trackedApplications` is a binary-plist array that alternates a key
    // ({bundle:{_0:id}}) and its value ({location:{bundle:{_0:id}}, isAllowed:...}).

    private func readEntries() -> [Any]? {
        guard let domain = domain,
              let data = CFPreferencesCopyValue(Self.key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Data,
              let entries = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any] else { return nil }
        return entries
    }

    // The bundle and entry of a value element; keys and ad hoc locations are nil.
    static func bundle(of element: Any) -> (String, [String: Any])? {
        guard let dict = element as? [String: Any], dict["isAllowed"] is Bool,
              let location = dict["location"] as? [String: Any],
              let id = (location["bundle"] as? [String: Any])?["_0"] as? String else { return nil }
        return (id, dict)
    }
}

// MARK: - Crash safety

// The apps this process switched off, so they can be switched back on after a
// crash, a force-quit or a quit: the switch is saved by macOS and outlives us.
final class HiddenAppsLedger {
    private let defaults: UserDefaults
    private let key = "HiddenAppsLedger"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var bundles: Set<String> {
        get { return Set(defaults.stringArray(forKey: key) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: key) }
    }
}

// MARK: - Backend for NativeVisibilityEngine

final class PerAppSwitchVisibility: NativeVisibilityProviding {
    private let store: AppSwitchStoring
    private let ledger: HiddenAppsLedger
    // Only the latest handle owns the hiding: an older one released after its
    // replacement took over (activate-then-drop) must not restore anything.
    private weak var current: Handle?

    init(store: AppSwitchStoring, ledger: HiddenAppsLedger = HiddenAppsLedger()) {
        self.store = store
        self.ledger = ledger
    }

    var isAvailable: Bool {
        return store.isAvailable
    }

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        guard let on = store.allowedBundles() else {
            return completion(.failure(NSError(domain: "HBPerAppSwitch", code: 1)))
        }
        let wanted = Set(hiddenBundleIdentifiers).subtracting(allowedBundleIdentifiers)
        // Only apps whose switch is on right now are ours to turn off: one the user
        // switched off themselves must not be switched back on later.
        let toHide = wanted.intersection(on)
        let toRestore = ledger.bundles.subtracting(wanted)
        // Ledger first: a crash between the two steps must still find the apps.
        ledger.bundles.formUnion(toHide)
        var changes = Dictionary(uniqueKeysWithValues: toHide.map { ($0, false) })
        toRestore.forEach { changes[$0] = true }
        guard store.setAllowed(changes) else {
            _ = restoreAll()
            return completion(.failure(NSError(domain: "HBPerAppSwitch", code: 2)))
        }
        ledger.bundles.subtract(toRestore)
        let handle = Handle(owner: self)
        current = handle
        completion(.success(handle))
    }

    // Switches back on everything this process hid. False if the list cannot be
    // written (no access yet); the ledger is kept then.
    @discardableResult
    func restoreAll() -> Bool {
        let hidden = ledger.bundles
        guard !hidden.isEmpty else { return true }
        guard store.isAvailable, store.setAllowed(Dictionary(uniqueKeysWithValues: hidden.map { ($0, true) })) else { return false }
        ledger.bundles = []
        return true
    }

    private func release(_ handle: Handle) {
        guard current === handle else { return }
        current = nil
        restoreAll()
    }

    private final class Handle: NativeVisibilityAssertion {
        private var owner: PerAppSwitchVisibility?

        init(owner: PerAppSwitchVisibility) {
            self.owner = owner
        }

        func invalidate() {
            guard let owner = owner else { return }
            self.owner = nil
            owner.release(self)
        }

        deinit {
            invalidate()
        }
    }
}

// MARK: - Engine choice

// macOS 27 engine with a fallback. Per-app switches keep the real Focus and timer;
// without access to the list (not granted yet, lost, format changed) it falls back
// to the restriction, which hides them, so their stand-ins are shown then.
// The engine is chosen at each collapse and kept until the bar is expanded.
final class MacOS27Engine: MenuBarEngine {
    private let perApp: NativeVisibilityEngine
    private let fallback: NativeVisibilityEngine
    private let visibility: PerAppSwitchVisibility
    private let store: AppSwitchStoring
    private let requestAccess: () -> Bool
    private lazy var active: NativeVisibilityEngine = fallback
    // The explainer and the panel are offered once per launch.
    private var offeredAccess = false

    init(items: MenuBarItemProvider,
         store: AppSwitchStoring = ControlCenterAppList.shared,
         ledger: HiddenAppsLedger = HiddenAppsLedger(),
         requestAccess: (() -> Bool)? = nil) {
        self.store = store
        visibility = PerAppSwitchVisibility(store: store, ledger: ledger)
        perApp = NativeVisibilityEngine(items: items, visibility: visibility)
        fallback = NativeVisibilityEngine(items: items)
        self.requestAccess = requestAccess ?? { MacOS27Engine.explainThenRequest(store) }
        // Apps a previous run left hidden.
        visibility.restoreAll()
    }

    var state: MenuBarEngineState { return active.state }
    var mayHideSystemItems: Bool { return true }
    var hidesSystemItems: Bool { return active === fallback }
    var isArrangementValid: Bool { return true }
    var isAlwaysHiddenSeparatorPlaced: Bool { return active.isAlwaysHiddenSeparatorPlaced }

    func collapse(completion: @escaping (CollapseResult) -> Void) {
        if active.state == .expanded || active.state == .unavailable {
            if !store.isAvailable && !offeredAccess {
                offeredAccess = true
                _ = requestAccess()
            }
            active = store.isAvailable ? perApp : fallback
        }
        active.collapse(completion: completion)
    }

    func expand() {
        active.expand()
    }

    func updateAlwaysHiddenSection(enabled: Bool, separatorHidden: Bool) {
        perApp.updateAlwaysHiddenSection(enabled: enabled, separatorHidden: separatorHidden)
        fallback.updateAlwaysHiddenSection(enabled: enabled, separatorHidden: separatorHidden)
    }

    func invalidateLayout() {
        perApp.invalidateLayout()
        fallback.invalidateLayout()
    }

    // The context-menu item: re-offer the grant.
    @discardableResult
    func grantAccess() -> Bool {
        return requestAccess()
    }

    // The context-menu "Restore hidden apps" and quit: every app this process hid
    // comes back, asking for the grant first if it is missing (not on quit).
    @discardableResult
    func restoreHiddenApps(askForAccess: Bool = true) -> Bool {
        return visibility.restoreAll() || (askForAccess && !store.isAvailable && requestAccess() && visibility.restoreAll())
    }

    private static func explainThenRequest(_ store: AppSwitchStoring) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Hide apps like System Settings does".localized
        alert.informativeText = "To keep Focus and the Clock timer visible while collapsed, Hidden Bar switches apps off in the menu bar the way System Settings does. Pick the file “group.com.apple.controlcenter.plist” in the next window. Hidden Bar only gets access to that one file. Without it, collapsing hides Focus and the timer too.".localized
        alert.addButton(withTitle: "Choose File…".localized)
        alert.addButton(withTitle: "Not Now".localized)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn && store.requestAccess()
    }
}
