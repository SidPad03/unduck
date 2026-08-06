import Foundation
import Combine
import AppKit
import SwiftUI
import CoreAudio
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "AppModel")

/// Fast-changing meter state, deliberately kept OUT of `AppModel`.
///
/// `@Published` fires `objectWillChange` on *every* assignment, including one
/// that writes back an identical value. Publishing the meter from `AppModel` at
/// 10 Hz therefore invalidated every view observing the model - including the
/// whole `MenuBarExtra` scene - ten times a second, forever, whether or not
/// anything had changed or anything was even on screen. Isolating it here means a
/// meter tick can only ever redraw the meter.
@MainActor
final class MeterModel: ObservableObject {
    @Published private(set) var level: Double = 0        // 0 to 1 for the UI bar
    @Published private(set) var limitingDB: Double = 0   // honest "limiting N dB" readout

    func update(level newLevel: Double, limitingDB newLimitingDB: Double) {
        if isChange(from: level, to: newLevel, epsilon: 0.005) { level = newLevel }
        if isChange(from: limitingDB, to: newLimitingDB, epsilon: 0.05) { limitingDB = newLimitingDB }
    }

    func reset() {
        if level != 0 { level = 0 }
        if limitingDB != 0 { limitingDB = 0 }
    }

    /// Ignore wiggle too small to see, but always honour a return to exactly zero
    /// so the bar can't get stranded just above the floor.
    private func isChange(from old: Double, to new: Double, epsilon: Double) -> Bool {
        new == 0 ? old != 0 : abs(new - old) > epsilon
    }
}

@MainActor
final class AppModel: ObservableObject {

    enum SessionState: Equatable {
        case idle, arming, active, error(String), unsupportedOS
    }

    enum Appearance: String { case menuBar, dock, both }

    /// Single shared instance so the AppDelegate (Dock reopen) reaches the same model.
    static let shared = AppModel()

    // Persisted settings. Each `didSet` guards on an actual change: SwiftUI writes
    // bindings back freely, and the side effects here (activation policy changes,
    // Service Management registration) are far too expensive to run on a no-op.
    @Published var autoActivate: Bool {
        didSet {
            guard autoActivate != oldValue else { return }
            defaults.set(autoActivate, forKey: "autoActivate")
        }
    }
    @Published var boostDB: Double {
        didSet {
            guard boostDB != oldValue else { return }
            defaults.set(boostDB, forKey: "boostDB")
            router.setBoost(dB: Float(boostDB))
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue, !applyingLaunchAtLogin else { return }
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var appearance: Appearance {
        didSet {
            guard appearance != oldValue else { return }
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
            if appearance == .dock { showControls() }   // don't strand the user with no menu-bar icon
        }
    }

    // Live state
    @Published private(set) var state: SessionState = .idle

    /// Meter readings land here rather than on `self` - see `MeterModel`.
    let meter = MeterModel()

    /// Estimated system duck depth (from the Phase 0 measurement). Drives the limiter ceiling.
    let duckDB: Float = 25.0

    let updater = Updater()

    private let defaults = UserDefaults.standard
    private let detector = CallDetector()
    private let router = AudioRouter()
    private let meterInterval: TimeInterval = 0.1
    private var meterTimer: DispatchSourceTimer?
    private var deviceListenerInstalled = false
    private var lastExclude: [AudioObjectID] = []
    private var lastComm: [AudioObjectID] = []
    private var armFailedThisCall = false
    private var manualSuppress = false   // user turned it off by hand; do not auto re-arm until the call ends
    private var applyingLaunchAtLogin = false
    private var controlsWindow: NSWindow?

    /// Main-thread view of whether the audio graph is up. The router builds and
    /// tears down asynchronously now, so it can no longer be asked synchronously.
    private var routerRunning = false

    /// Bumped by every arm/disarm, so a completion from a superseded operation is
    /// recognised as stale and ignored.
    private var opToken = 0

    var isActive: Bool { state == .active }

    var isSupportedOS: Bool {
        // Real routing needs the 26.1 aggregate-sample-rate fix (spec section 3.4). You are on 26.5.
        if #available(macOS 26.1, *) { return true } else { return false }
    }

    init() {
        defaults.register(defaults: ["autoActivate": true, "boostDB": 25.0, "appearance": Appearance.menuBar.rawValue])
        autoActivate = defaults.bool(forKey: "autoActivate")
        boostDB = defaults.double(forKey: "boostDB")
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .menuBar

        router.expectedDuckDB = duckDB
        AudioRouter.sweepOrphans()   // clean up anything a prior crash left muted or aggregated

        if !isSupportedOS { state = .unsupportedOS }

        detector.onChange = { [weak self] active, comm in self?.handleCall(active: active, comm: comm) }
        detector.start()
        installDeviceListener()
        // The meter timer runs only while the graph is up - see arm()/disarm().

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.updater.check(interactive: false) }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            // Must actually be down before the machine sleeps, so this one waits.
            MainActor.assumeIsolated { self?.disarm(synchronously: true) }
        }

        applyAppearance()
    }

    // MARK: call handling

    private func handleCall(active: Bool, comm: [AudioObjectID]) {
        guard isSupportedOS else { return }
        lastComm = comm
        if active {
            let exclude = excludeList(comm: comm)
            if routerRunning {
                if exclude != lastExclude { arm(exclude: exclude) }
            } else if autoActivate, !manualSuppress, !armFailedThisCall {
                arm(exclude: exclude)
            }
        } else {
            armFailedThisCall = false
            manualSuppress = false
            disarm()
        }
    }

    /// Manual on/off from the menu. Overrides auto for the current call.
    func setManual(_ on: Bool) {
        guard isSupportedOS else { return }
        if on {
            manualSuppress = false
            armFailedThisCall = false
            let comm = lastComm.isEmpty ? detector.currentCommProcesses() : lastComm
            if !routerRunning { arm(exclude: excludeList(comm: comm)) }
        } else {
            manualSuppress = true      // block auto re-arm until the call ends
            disarm()
        }
    }

    private func excludeList(comm: [AudioObjectID]) -> [AudioObjectID] {
        var list = comm
        if let own = CA.ownProcessObject { list.append(own) }   // never feed our own output back
        return list
    }

    /// Build (or rebuild) the graph. The HAL work happens off the main thread; the
    /// UI flips to `.arming` immediately and settles when the completion lands.
    private func arm(exclude: [AudioObjectID]) {
        opToken &+= 1
        let token = opToken
        state = .arming
        router.start(excludeProcesses: exclude, boostDB: Float(boostDB)) { [weak self] result in
            guard let self, token == self.opToken else { return }   // superseded
            switch result {
            case .success:
                self.lastExclude = exclude
                self.routerRunning = true
                self.state = .active
                self.startMeter()
            case .failure(let error):
                self.armFailedThisCall = true
                self.routerRunning = false
                self.state = .error("\(error)")
                self.stopMeter()
                log.error("arm failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func disarm(synchronously: Bool = false) {
        opToken &+= 1          // invalidate any arm still in flight
        routerRunning = false
        stopMeter()
        state = .idle
        // Teardown is serialised behind any in-flight build on the router's own
        // queue, so ordering holds even if a start is still running.
        if synchronously { router.stopSynchronously() } else { router.stop() }
    }

    // MARK: device changes

    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.routerRunning else { return }
                log.info("default output changed, rebuilding router")
                self.arm(exclude: self.lastExclude)
            }
        }
        deviceListenerInstalled = (status == noErr)
    }

    // MARK: metering

    /// Runs only while the graph is up. A dispatch timer rather than a `Timer` so
    /// it keeps ticking in event-tracking run loop modes - the meter stays live
    /// while the user is dragging the slider.
    private func startMeter() {
        guard meterTimer == nil else { return }
        let ceiling = powf(10.0, (duckDB - 0.5) / 20.0)
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + meterInterval, repeating: meterInterval, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let (peak, limiting) = self.router.meters()
                self.meter.update(level: Double(min(1, max(0, peak / ceiling))),
                                  limitingDB: Double(limiting))
            }
        }
        meterTimer = t
        t.resume()
    }

    private func stopMeter() {
        meterTimer?.cancel()
        meterTimer = nil
        meter.reset()
    }

    // MARK: launch at login

    private func applyLaunchAtLogin(_ on: Bool) {
        // SMAppService register/unregister is a synchronous XPC round-trip to
        // servicemanagementd, so it does not belong on the main thread - that was
        // the stall you felt when flipping the switch.
        Task.detached(priority: .utility) {
            do {
                if on { try SMAppService.mainApp.register() } else { try await SMAppService.mainApp.unregister() }
            } catch {
                log.error("launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
                let actual = (SMAppService.mainApp.status == .enabled)
                await MainActor.run { [weak self] in
                    guard let self, self.launchAtLogin != actual else { return }
                    // Put the switch back where reality is, without re-triggering.
                    self.applyingLaunchAtLogin = true
                    self.launchAtLogin = actual
                    self.applyingLaunchAtLogin = false
                }
            }
        }
    }

    // MARK: appearance (Dock / menu bar / both)

    func applyAppearance() {
        // setActivationPolicy round-trips to the window server; skip it when the
        // policy already matches (this is called on launch as well as on change).
        let policy: NSApplication.ActivationPolicy = (appearance == .menuBar) ? .accessory : .regular
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        if appearance == .menuBar { controlsWindow?.orderOut(nil) }
    }

    /// Show the controls in a real window. Used when the menu-bar icon is hidden
    /// (Dock-only) or when the user clicks the Dock icon.
    func showControls() {
        if controlsWindow == nil {
            let host = NSHostingController(rootView: PopoverView().environmentObject(self))
            host.sizingOptions = [.preferredContentSize]
            let w = NSWindow(contentViewController: host)
            w.title = "Unduck"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            controlsWindow = w
        }
        controlsWindow?.center()
        controlsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: teardown

    func shutDown() {
        stopMeter()
        detector.stop()
        // Blocking: the process must not exit with the tap still installed, or
        // every media app stays muted.
        router.stopSynchronously()
    }

    var statusText: String {
        switch state {
        case .idle:          return "Waiting for a call"
        case .arming:        return "Starting"
        case .active:        return "On a call, media unducked"
        case .error(let m):  return "Error: \(m)"
        case .unsupportedOS: return "Needs macOS 26.1 or later"
        }
    }

    /// Small state glyph shown inside the popover (the menu-bar icon itself is the duck).
    var menuBarSymbol: String {
        switch state {
        case .active:                return "speaker.wave.2.fill"
        case .error, .unsupportedOS: return "exclamationmark.triangle"
        default:                     return "speaker.wave.2"
        }
    }
}
