//
//  MenuBarEngineTests.swift
//  HiddenBarTests
//
//  Copyright © 2026 Dwarves Foundation. All rights reserved.
//

import AppKit
import XCTest

// The engine sources are compiled straight into this bundle (no host app), so
// the tests never put items in the real menu bar, never need Accessibility, and
// never touch the private visibility API.

// MARK: - Fakes

private final class FakeItems: MenuBarItemProvider {
    private let bar = NSStatusBar()
    let toggleItem: NSStatusItem
    let separatorItem: NSStatusItem
    var alwaysHiddenItem: NSStatusItem?

    init() {
        toggleItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        separatorItem = bar.statusItem(withLength: 1)
        alwaysHiddenItem = bar.statusItem(withLength: 20)
    }
}

private final class FakeInventory: MenuBarInventoryProviding {
    var isAuthorized = true
    var items: [MenuBarInventoryItem] = []
    var authorizationRequests = 0
    var snapshots = 0

    func requestAuthorization() {
        authorizationRequests += 1
    }

    func snapshot(completion: @escaping ([MenuBarInventoryItem]) -> Void) {
        snapshots += 1
        completion(items)
    }
}

private final class FakeAssertion: NativeVisibilityAssertion {
    let allowed: [String]
    private(set) var isInvalidated = false
    var onInvalidate: (() -> Void)?

    init(allowed: [String]) {
        self.allowed = allowed
    }

    func invalidate() {
        isInvalidated = true
        onInvalidate?()
    }
}

// Hands every activation to the test, which decides when and how it completes.
private final class FakeVisibility: NativeVisibilityProviding {
    struct Request {
        let systemItems: [Int]
        let bundles: [String]
        let completion: (Result<NativeVisibilityAssertion, Error>) -> Void
    }

    var isAvailable = true
    var requests: [Request] = []

    func activate(allowedSystemItems: [Int],
                  allowedBundleIdentifiers: [String],
                  hiddenBundleIdentifiers: [String],
                  completion: @escaping (Result<NativeVisibilityAssertion, Error>) -> Void) {
        requests.append(Request(systemItems: allowedSystemItems, bundles: allowedBundleIdentifiers, completion: completion))
    }

    @discardableResult
    func succeed(_ index: Int) -> FakeAssertion {
        let assertion = FakeAssertion(allowed: requests[index].bundles)
        requests[index].completion(.success(assertion))
        return assertion
    }

    func fail(_ index: Int) {
        requests[index].completion(.failure(NSError(domain: "test", code: 1)))
    }
}

private func item(_ bundle: String?, x: CGFloat, width: CGFloat = 24) -> MenuBarInventoryItem {
    return MenuBarInventoryItem(bundleIdentifier: bundle, frame: CGRect(x: x, y: 0, width: width, height: 24))
}

// LTR bar used throughout: always-hidden separator at 1000, the boundary at 1300
// (the separator for the resolver, the arrow for the native engine).
private let alwaysHiddenSeparator = CGRect(x: 1000, y: 0, width: 20, height: 24)
private let separator = CGRect(x: 1300, y: 0, width: 20, height: 24)

// MARK: - Layout resolver

final class MenuBarLayoutResolverTests: XCTestCase {
    func testLTRSectionsFollowSeparators() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: alwaysHiddenSeparator,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.always": .alwaysHidden, "com.hidden": .hidden, "com.visible": .visible])
    }

    func testRTLSectionsAreMirrored() {
        // RTL: arrow on the left, separator just right of it, hidden further right.
        let rtlSeparator = CGRect(x: 300, y: 0, width: 20, height: 24)
        let rtlAlwaysHidden = CGRect(x: 600, y: 0, width: 20, height: 24)
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.visible", x: 200), item("com.hidden", x: 450), item("com.always", x: 700)],
            separatorFrame: rtlSeparator, alwaysHiddenSeparatorFrame: rtlAlwaysHidden,
            isLTR: false, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.always": .alwaysHidden, "com.hidden": .hidden, "com.visible": .visible])
    }

    func testWithoutAlwaysHiddenSeparatorEverythingLeftIsHidden() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.far", x: 100), item("com.near", x: 1200)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: nil,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections, ["com.far": .hidden, "com.near": .hidden])
    }

    func testMostVisibleItemWinsForABundle() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.split", x: 1100), item("com.split", x: 1400),
                        item("com.pair", x: 900), item("com.pair", x: 1100)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: alwaysHiddenSeparator,
            isLTR: true, excludingBundle: nil)
        XCTAssertEqual(layout.sections["com.split"], .visible)
        XCTAssertEqual(layout.sections["com.pair"], .hidden)
    }

    func testSkipsOwnSystemAndUnidentifiedItems() {
        let layout = MenuBarLayoutResolver.resolve(
            inventory: [item("com.dwarvesv.minimalbar", x: 1100), item("com.apple.MenuBarAgent", x: 1100),
                        item(nil, x: 1100), item("com.app", x: 1100)],
            separatorFrame: separator, alwaysHiddenSeparatorFrame: nil,
            isLTR: true, excludingBundle: "com.dwarvesv.minimalbar")
        XCTAssertEqual(layout.sections, ["com.app": .hidden])
    }

    func testBundlesAreFilteredAndSorted() {
        let layout = MenuBarLayout(sections: ["b": .visible, "a": .visible, "c": .hidden, "d": .alwaysHidden])
        XCTAssertEqual(layout.bundles(in: [.visible]), ["a", "b"])
        XCTAssertEqual(layout.bundles(in: [.visible, .hidden]), ["a", "b", "c"])
    }
}

// MARK: - Native engine

final class NativeVisibilityEngineTests: XCTestCase {
    private var items: FakeItems!
    private var inventory: FakeInventory!
    private var visibility: FakeVisibility!

    override func setUp() {
        super.setUp()
        items = FakeItems()
        inventory = FakeInventory()
        inventory.items = [item("com.always", x: 900), item("com.hidden", x: 1100), item("com.visible", x: 1400)]
        visibility = FakeVisibility()
    }

    private func makeEngine() -> NativeVisibilityEngine {
        let items = self.items!
        return NativeVisibilityEngine(items: items, inventory: inventory, visibility: visibility,
                                      ownBundleIdentifier: "com.dwarvesv.minimalbar",
                                      itemFrame: { $0 === items.toggleItem ? separator : alwaysHiddenSeparator },
                                      isLTR: { true })
    }

    func testCollapseKeepsOnlyVisibleAppsAndSystemItems() {
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        XCTAssertEqual(engine.state, .calibrating)
        XCTAssertEqual(visibility.requests.first?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        XCTAssertEqual(visibility.requests.first?.systemItems, NativeVisibilityEngine.systemItemsToKeep)
        XCTAssertFalse(items.separatorItem.isVisible, "the arrow is the boundary; no separator needed")

        visibility.succeed(0)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(results, [.collapsed])

        engine.expand()
        XCTAssertFalse(items.separatorItem.isVisible)
    }

    func testAlwaysHiddenSeparatorFollowsTheSectionSetting() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: false, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: false)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)

        engine.collapse { _ in }
        visibility.succeed(visibility.requests.count - 1)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0)

        engine.expand()
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20)
    }

    func testUnavailableAPIFailsOpen() {
        visibility.isAvailable = false
        let engine = makeEngine()
        var result: CollapseResult?
        engine.collapse { result = $0 }

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(engine.state, .unavailable)
        XCTAssertTrue(visibility.requests.isEmpty)
    }

    func testMissingAccessibilityAsksAndRetriesLater() {
        inventory.isAuthorized = false
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        XCTAssertEqual(results, [.unavailable])
        XCTAssertEqual(inventory.authorizationRequests, 1)
        XCTAssertTrue(visibility.requests.isEmpty, "never guess which icons to hide")

        inventory.isAuthorized = true
        engine.collapse { results.append($0) }
        XCTAssertEqual(visibility.requests.count, 1, "works once the permission is granted")
    }

    func testActivationFailureReportsUnavailable() {
        let engine = makeEngine()
        var result: CollapseResult?
        engine.collapse { result = $0 }
        visibility.fail(0)

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 0, "the always-hidden separator only shows when enabled")
    }

    func testExpandDropsTheRestriction() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        engine.expand()
        XCTAssertTrue(collapsed.isInvalidated)
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(visibility.requests.count, 1)
    }

    func testExpandKeepsAlwaysHiddenSectionHiddenAndSwapsWithoutFlashing() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        // Expanded with separators hidden: everything but always-hidden is shown.
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
        visibility.succeed(visibility.requests.count - 1)

        engine.collapse { _ in }
        let collapseIndex = visibility.requests.count - 1
        XCTAssertEqual(visibility.requests[collapseIndex].bundles, ["com.dwarvesv.minimalbar", "com.visible"])
        let collapsed = visibility.succeed(collapseIndex)

        var newIsActiveWhenOldDropped = false
        collapsed.onInvalidate = { newIsActiveWhenOldDropped = true }
        engine.expand()
        let expandIndex = visibility.requests.count - 1
        XCTAssertEqual(visibility.requests[expandIndex].bundles, ["com.dwarvesv.minimalbar", "com.hidden", "com.visible"])
        XCTAssertFalse(collapsed.isInvalidated, "the old restriction stays until the new one is active")
        visibility.succeed(expandIndex)
        XCTAssertTrue(newIsActiveWhenOldDropped)
    }

    func testSectionsAreNotReadWhileSomethingIsHidden() {
        let engine = makeEngine()
        engine.updateAlwaysHiddenSection(enabled: true, separatorHidden: true)
        visibility.succeed(visibility.requests.count - 1)
        let snapshotsBefore = inventory.snapshots

        // Hidden items would report stale positions now; the cached layout is used.
        inventory.items = [item("com.visible", x: 100)]
        engine.collapse { _ in }
        XCTAssertEqual(inventory.snapshots, snapshotsBefore)
        XCTAssertEqual(visibility.requests.last?.bundles, ["com.dwarvesv.minimalbar", "com.visible"])
    }

    func testExpandDuringActivationDropsTheLateResult() {
        let engine = makeEngine()
        var results: [CollapseResult] = []
        engine.collapse { results.append($0) }

        engine.expand()
        let late = visibility.succeed(0)

        XCTAssertTrue(late.isInvalidated, "a restriction nobody wants any more is released")
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(results, [])
    }

    func testDisplayChangeKeepsTheBarCollapsed() {
        let engine = makeEngine()
        engine.collapse { _ in }
        let collapsed = visibility.succeed(0)

        engine.invalidateLayout()
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertFalse(collapsed.isInvalidated)
    }
}

// MARK: - Legacy engine

final class LegacyLengthEngineTests: XCTestCase {
    func testCollapseAndExpandFlipSeparatorLength() {
        let items = FakeItems()
        let engine = LegacyLengthEngine(items: items)
        XCTAssertEqual(engine.state, .expanded)

        var result: CollapseResult?
        engine.collapse { result = $0 }
        XCTAssertEqual(result, .collapsed)
        XCTAssertEqual(engine.state, .collapsed)
        XCTAssertEqual(items.alwaysHiddenItem?.length, 20, "collapse leaves the always-hidden item alone")

        engine.expand()
        XCTAssertEqual(engine.state, .expanded)
        XCTAssertEqual(items.separatorItem.length, 20)
    }
}

// MARK: - Focus database

final class FocusDatabaseTests: XCTestCase {
    func testReadsModesAndTheLatestActiveMode() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("""
        {"data":[{"modeConfigurations":{
          "a":{"mode":{"name":"Work","modeIdentifier":"com.apple.focus.work","symbolImageName":"briefcase.fill"}},
          "b":{"mode":{"name":"Fitness","modeIdentifier":"com.apple.focus.fitness","symbolImageName":"heart.fill"}},
          "c":{"mode":{"name":"Reduce Interruptions","modeIdentifier":"com.apple.focus.reduce-interruptions","symbolImageName":"moon.fill"}}
        }}]}
        """.utf8).write(to: directory.appendingPathComponent("ModeConfigurations.json"))
        try Data("""
        {"data":[{"storeAssertionRecords":[
          {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"},"assertionStartDateTimestamp":10},
          {"assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.fitness"},"assertionStartDateTimestamp":20}
        ]}]}
        """.utf8).write(to: directory.appendingPathComponent("Assertions.json"))

        let modes = try FocusItemController.readModes(from: directory)
        XCTAssertEqual(modes.map(\.name), ["Fitness", "Reduce Interruptions", "Work"])
        XCTAssertEqual(modes.first?.symbolName, "heart.fill")
        XCTAssertEqual(modes[1].symbolName, "_gm", "Reduce Interruptions shows the Apple Intelligence glyph, not its legacy moon")
        XCTAssertNotNil(NSImage(systemSymbolName: modes[1].symbolName, accessibilityDescription: nil))
        XCTAssertEqual(try FocusItemController.readActiveModeIdentifier(from: directory), "com.apple.focus.fitness")

        try Data(#"{"data":[{"storeAssertionRecords":[]}]}"#.utf8).write(to: directory.appendingPathComponent("Assertions.json"))
        XCTAssertNil(try FocusItemController.readActiveModeIdentifier(from: directory), "no assertion means Focus is off")
    }
}

// MARK: - Clock timers

final class TimerItemTests: XCTestCase {
    func testSoonestRunningOrPausedTimerWins() {
        let now = Date(timeIntervalSince1970: 1_000)
        func timer(_ state: Int, _ fireTime: [String: Any]) -> [String: Any] {
            return ["$MTTimer": ["MTTimerState": state, "MTTimerFireTime": fireTime]]
        }
        let running = timer(3, ["$MTTimerDate": ["MTTimerTimeDate": now.addingTimeInterval(1_522)]])
        let paused = timer(2, ["$MTTimerTimeInterval": ["MTTimerTimeInterval": 300.0]])
        let idle = timer(1, ["$MTTimerTimeInterval": ["MTTimerTimeInterval": 60.0]])

        XCTAssertNil(TimerItemController.activeTimer(in: [idle], now: now), "an idle timer hides the item")
        XCTAssertEqual(TimerItemController.activeTimer(in: [idle, running], now: now),
                       .init(remaining: 1_522, isPaused: false))
        XCTAssertEqual(TimerItemController.activeTimer(in: [running, paused], now: now),
                       .init(remaining: 300, isPaused: true))
        XCTAssertEqual(TimerItemController.format(1_522), "25:22")
        XCTAssertEqual(TimerItemController.format(3_723), "1:02:03")
    }
}

// MARK: - Per-app switches

private final class FakeAppSwitches: AppSwitchStoring {
    var isAvailable = true
    var on: Set<String>
    var writes: [[String: Bool]] = []
    var failWrites = false
    var grants = 0

    init(on: Set<String>) {
        self.on = on
    }

    func allowedBundles() -> Set<String>? {
        return isAvailable ? on : nil
    }

    func setAllowed(_ changes: [String: Bool]) -> Bool {
        guard isAvailable, !failWrites else { return false }
        writes.append(changes)
        for (bundle, allowed) in changes {
            if allowed { on.insert(bundle) } else { on.remove(bundle) }
        }
        return true
    }

    func requestAccess() -> Bool {
        grants += 1
        isAvailable = true
        return true
    }
}

final class PerAppSwitchVisibilityTests: XCTestCase {
    private var defaults: UserDefaults!
    private var switches: FakeAppSwitches!
    private var ledger: HiddenAppsLedger!
    private var visibility: PerAppSwitchVisibility!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PerAppSwitchVisibilityTests")!
        defaults.removePersistentDomain(forName: "PerAppSwitchVisibilityTests")
        switches = FakeAppSwitches(on: ["a", "b", "c"])
        ledger = HiddenAppsLedger(defaults: defaults)
        visibility = PerAppSwitchVisibility(store: switches, ledger: ledger)
    }

    private func activate(allowing: [String] = ["own"], hiding: [String]) -> Result<NativeVisibilityAssertion, Error> {
        var result: Result<NativeVisibilityAssertion, Error>!
        visibility.activate(allowedSystemItems: [], allowedBundleIdentifiers: allowing, hiddenBundleIdentifiers: hiding) { result = $0 }
        return result
    }

    func testActivateSwitchesOffOnlyHiddenAppsAndReleaseRestoresThem() throws {
        let assertion = try activate(hiding: ["a", "b"]).get()
        XCTAssertEqual(switches.on, ["c"])
        XCTAssertEqual(ledger.bundles, ["a", "b"])

        assertion.invalidate()
        XCTAssertEqual(switches.on, ["a", "b", "c"])
        XCTAssertEqual(ledger.bundles, [])
    }

    func testAnAppTheUserSwitchedOffIsNeverRecordedNorRestored() throws {
        switches.on = ["b", "c"]
        let assertion = try activate(hiding: ["a", "b"]).get()
        XCTAssertEqual(ledger.bundles, ["b"])

        assertion.invalidate()
        XCTAssertEqual(switches.on, ["b", "c"], "b was on when hidden and comes back; a was off before and stays off")
    }

    func testReplacingTheActivationNeverRestoresWhatTheNewOneHides() throws {
        let old = try activate(hiding: ["a", "b"]).get()
        let new = try activate(hiding: ["b"]).get()
        XCTAssertEqual(switches.on, ["a", "c"], "a is back, b stays hidden")

        old.invalidate()
        XCTAssertEqual(switches.on, ["a", "c"], "the superseded handle restores nothing")

        new.invalidate()
        XCTAssertEqual(switches.on, ["a", "b", "c"])
    }

    func testFailedWriteRestoresAndFailsOpen() {
        switches.failWrites = true
        guard case .failure = activate(hiding: ["a"]) else { return XCTFail("expected a failure") }
        switches.failWrites = false
        XCTAssertTrue(visibility.restoreAll())
        XCTAssertEqual(switches.on, ["a", "b", "c"])
        XCTAssertEqual(ledger.bundles, [])
    }

    func testRestoreKeepsTheLedgerWhileTheListIsUnreachable() throws {
        _ = try activate(hiding: ["a"]).get()
        switches.isAvailable = false
        XCTAssertFalse(visibility.restoreAll())
        XCTAssertEqual(ledger.bundles, ["a"])

        switches.isAvailable = true
        XCTAssertTrue(visibility.restoreAll())
        XCTAssertEqual(switches.on, ["a", "b", "c"])
    }

    func testValueElementsAreDecodedAndKeysAndAdHocLocationsAreSkipped() {
        let value: [String: Any] = ["location": ["bundle": ["_0": "com.x"]], "isAllowed": true]
        XCTAssertEqual(ControlCenterAppList.bundle(of: value)?.0, "com.x")
        XCTAssertNil(ControlCenterAppList.bundle(of: ["bundle": ["_0": "com.x"]]))
        XCTAssertNil(ControlCenterAppList.bundle(of: ["location": ["adhocBinary": ["_0": "x"]], "isAllowed": true]))
    }
}

final class MacOS27EngineTests: XCTestCase {
    private var items: FakeItems!
    private var switches: FakeAppSwitches!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        items = FakeItems()
        defaults = UserDefaults(suiteName: "MacOS27EngineTests")!
        defaults.removePersistentDomain(forName: "MacOS27EngineTests")
        switches = FakeAppSwitches(on: ["a"])
    }

    func testLaunchRestoresAppsAPreviousRunLeftHidden() {
        let ledger = HiddenAppsLedger(defaults: defaults)
        ledger.bundles = ["a"]
        switches.on = []
        _ = MacOS27Engine(items: items, store: switches, ledger: ledger, requestAccess: { false })
        XCTAssertEqual(switches.on, ["a"])
        XCTAssertEqual(ledger.bundles, [])
    }

    func testWithoutAccessItOffersOnceThenFallsBackToTheRestriction() {
        switches.isAvailable = false
        var offers = 0
        let engine = MacOS27Engine(items: items, store: switches, ledger: HiddenAppsLedger(defaults: defaults),
                                   requestAccess: { offers += 1; return false })
        engine.collapse { _ in }
        engine.collapse { _ in }
        XCTAssertEqual(offers, 1)
        XCTAssertTrue(engine.hidesSystemItems, "the fallback restriction hides Focus and the timer, so the stand-ins show")
    }

    func testWithAccessThePerAppEngineKeepsTheRealItems() {
        let engine = MacOS27Engine(items: items, store: switches, ledger: HiddenAppsLedger(defaults: defaults),
                                   requestAccess: { false })
        engine.collapse { _ in }
        XCTAssertFalse(engine.hidesSystemItems)
        XCTAssertTrue(engine.mayHideSystemItems)
    }

    func testAGrantGivenAtTheFirstCollapseIsUsedImmediately() {
        switches.isAvailable = false
        let engine = MacOS27Engine(items: items, store: switches, ledger: HiddenAppsLedger(defaults: defaults),
                                   requestAccess: { [switches] in switches!.requestAccess() })
        engine.collapse { _ in }
        XCTAssertFalse(engine.hidesSystemItems)
    }
}
