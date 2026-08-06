import Foundation
import Combine
import AppKit
import SwiftUI
import CoreAudio
import ServiceManagement
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "AppModel")

@MainActor
final class AppModel: ObservableObject {

    enum SessionState: Equatable {
        case idle, arming, active, error(String), unsupportedOS
    }

    enum Appearance: String { case menuBar, dock, both }

    /// Single shared instance so the AppDelegate (Dock reopen) reaches the same model.
    static let shared = AppModel()

    // Persisted settings
    @Published var autoActivate: Bool  { didSet { defaults.set(autoActivate, forKey: "autoActivate") } }
    @Published var boostDB: Double     { didSet { defaults.set(boostDB, forKey: "boostDB"); router.setBoost(dB: Float(boostDB)) } }
    @Published var launchAtLogin: Bool { didSet { applyLaunchAtLogin(launchAtLogin) } }
    @Published var appearance: Appearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
            if appearance == .dock { showControls() }   // don't strand the user with no menu-bar icon
        }
    }

    // Live state
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var meterLevel: Double = 0     // 0 to 1 for the UI bar
    @Published private(set) var limitingDB: Double = 0     // honest "limiting N dB" readout

    /// Estimated system duck depth (from the Phase 0 measurement). Drives the limiter ceiling.
    let duckDB: Float = 25.0

    let updater = Updater()

    private let defaults = UserDefaults.standard
    private let detector = CallDetector()
    private let router = AudioRouter()
    private var meterTimer: Timer?
    private var deviceListenerInstalled = false
    private var lastExclude: [AudioObjectID] = []
    private var lastComm: [AudioObjectID] = []
    private var armFailedThisCall = false
    private var manualSuppress = false   // user turned it off by hand; do not auto re-arm until the call ends
    private var controlsWindow: NSWindow?

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

        AudioRouter.sweepOrphans()   // clean up anything a prior crash left muted or aggregated
        router.expectedDuckDB = duckDB

        if !isSupportedOS { state = .unsupportedOS }

        detector.onChange = { [weak self] active, comm in self?.handleCall(active: active, comm: comm) }
        detector.start()
        installDeviceListener()
        startMeter()

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.updater.check(interactive: false) }

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDown() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.router.stop(); self?.state = .idle }
        }

        applyAppearance()
    }

    // MARK: call handling

    private func handleCall(active: Bool, comm: [AudioObjectID]) {
        guard isSupportedOS else { return }
        lastComm = comm
        if active {
            let exclude = excludeList(comm: comm)
            if router.isRunning {
                if exclude != lastExclude { rebuild(exclude: exclude) }
            } else if autoActivate, !manualSuppress, !armFailedThisCall {
                arm(exclude: exclude)
            }
        } else {
            armFailedThisCall = false
            manualSuppress = false
            if router.isRunning { router.stop() }
            state = .idle
        }
    }

    /// Manual on/off from the menu. Overrides auto for the current call.
    func setManual(_ on: Bool) {
        guard isSupportedOS else { return }
        if on {
            manualSuppress = false
            armFailedThisCall = false
            let comm = lastComm.isEmpty ? detector.currentCommProcesses() : lastComm
            if !router.isRunning { arm(exclude: excludeList(comm: comm)) }
        } else {
            manualSuppress = true      // block auto re-arm until the call ends
            if router.isRunning { router.stop() }
            state = .idle
        }
    }

    private func excludeList(comm: [AudioObjectID]) -> [AudioObjectID] {
        var list = comm
        if let own = CA.processObject(forPID: getpid()) { list.append(own) }   // never feed our own output back
        return list
    }

    private func arm(exclude: [AudioObjectID]) {
        state = .arming
        do {
            try router.start(excludeProcesses: exclude, boostDB: Float(boostDB))
            lastExclude = exclude
            state = .active
        } catch {
            armFailedThisCall = true
            state = .error("\(error)")
            log.error("arm failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func rebuild(exclude: [AudioObjectID]) {
        router.stop()
        do {
            try router.start(excludeProcesses: exclude, boostDB: Float(boostDB))
            lastExclude = exclude
            state = .active
        } catch {
            state = .error("\(error)")
        }
    }

    // MARK: device changes

    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.router.isRunning else { return }
                log.info("default output changed, rebuilding router")
                self.rebuild(exclude: self.lastExclude)
            }
        }
        deviceListenerInstalled = (status == noErr)
    }

    // MARK: metering

    private func startMeter() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ceiling = powf(10.0, (self.duckDB - 0.5) / 20.0)
                self.meterLevel = self.router.isRunning ? Double(min(1, max(0, self.router.meterPeak / ceiling))) : 0
                self.limitingDB = self.router.isRunning ? Double(self.router.limitingDB) : 0
            }
        }
    }

    // MARK: launch at login

    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("launch at login toggle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: appearance (Dock / menu bar / both)

    func applyAppearance() {
        switch appearance {
        case .menuBar:
            NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
            controlsWindow?.orderOut(nil)
        case .dock, .both:
            NSApp.setActivationPolicy(.regular)     // Dock icon
        }
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

    func shutDown() { router.stop(); detector.stop(); meterTimer?.invalidate() }

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
