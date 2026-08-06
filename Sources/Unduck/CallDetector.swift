import Foundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "CallDetector")

/// Detects an active call by watching whether any communication process has its
/// mic running (`kAudioProcessPropertyIsRunningInput`). A 4 Hz poll is used
/// instead of HAL property listeners because listeners are known to miss
/// transitions (spec section 5.1); polling is simple and never gets stuck.
/// Debounced so transient mic blips do not flap the audio graph.
///
/// The poll runs on a background queue and only touches the main thread when the
/// answer actually changes. Two things make it cheap:
///
///  * Bundle IDs are cached per process object. Every HAL read is a synchronous
///    XPC round-trip to coreaudiod, and asking every audio process for its bundle
///    ID four times a second meant hundreds of round-trips per second - on the
///    main thread, which is what made the menu stutter. Object IDs are stable for
///    the life of a process object, so the answer never needs re-fetching.
///  * `onChange` fires on transitions only. It used to fire every single tick
///    while a call was up, re-running the whole arm/rebuild decision at 4 Hz.
final class CallDetector {

    /// Verified on macOS 26.5: a FaceTime call's mic + voice are owned by
    /// `com.apple.avconferenced` (the AV Conference daemon), NOT FaceTime.app.
    /// We match the daemon; FaceTime.app is kept as a harmless extra.
    static let defaultCommBundleIDs: Set<String> = [
        "com.apple.avconferenced",
        "com.apple.FaceTime",
    ]

    private let commBundleIDs: Set<String>
    private let pollInterval: TimeInterval = 0.25
    private let activateAfter = 3     // ~0.75 s of continuous mic use
    private let deactivateAfter = 8   // ~2.0 s of no mic use

    /// All HAL polling happens here, never on main.
    private let queue = DispatchQueue(label: "com.sigmanet.unduck.calldetector", qos: .utility)

    // Everything below is owned by `queue`.
    private var timer: DispatchSourceTimer?
    private var trueStreak = 0
    private var falseStreak = 0
    private var reportedActive = false
    private var reportedComm: [AudioObjectID] = []
    private var lastComm: [AudioObjectID] = []
    /// Process object -> bundle ID (nil means "asked, it has none").
    private var bundleIDs: [AudioObjectID: String?] = [:]

    /// (callActive, communicationProcessObjectIDs). Delivered on the main queue.
    var onChange: ((Bool, [AudioObjectID]) -> Void)?

    init(commBundleIDs: Set<String> = CallDetector.defaultCommBundleIDs) {
        self.commBundleIDs = commBundleIDs
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway: this is a background heartbeat, so let the kernel
        // coalesce it with other timers instead of waking the CPU on its own.
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
        log.info("call detector started (\(self.commBundleIDs.joined(separator: ","), privacy: .public))")
    }

    func stop() { timer?.cancel(); timer = nil }

    /// The communication processes seen by the most recent poll. Cheap - answers
    /// from the poller's cache rather than re-walking the HAL on the main thread.
    func currentCommProcesses() -> [AudioObjectID] {
        queue.sync { lastComm }
    }

    private func poll() {
        let processes = CA.processObjects

        // Forget processes that have gone away so the cache tracks reality rather
        // than growing for the life of the app.
        if bundleIDs.count > processes.count {
            let live = Set(processes)
            bundleIDs = bundleIDs.filter { live.contains($0.key) }
        }

        var comm: [AudioObjectID] = []
        var anyInput = false
        for process in processes {
            let bundleID: String?
            if let cached = bundleIDs[process] {
                bundleID = cached
            } else {
                bundleID = CA.bundleID(ofProcess: process)
                bundleIDs[process] = bundleID
            }
            guard let bundleID, commBundleIDs.contains(bundleID) else { continue }
            comm.append(process)
            if !anyInput, CA.isRunningInput(process) { anyInput = true }
        }
        // Stable order, so an unchanged set never looks like a change downstream.
        comm.sort()
        lastComm = comm

        if anyInput { trueStreak += 1; falseStreak = 0 } else { falseStreak += 1; trueStreak = 0 }

        if !reportedActive, trueStreak >= activateAfter {
            reportedActive = true
            reportedComm = comm
            log.info("call ACTIVE")
            emit(true, comm)
        } else if reportedActive, falseStreak >= deactivateAfter {
            reportedActive = false
            reportedComm = []
            log.info("call ENDED")
            emit(false, [])
        } else if reportedActive, comm != reportedComm {
            // Still on a call, but the comm-process set moved (PIDs can change);
            // the router's exclusion list has to follow.
            reportedComm = comm
            emit(true, comm)
        }
    }

    private func emit(_ active: Bool, _ comm: [AudioObjectID]) {
        DispatchQueue.main.async { [weak self] in self?.onChange?(active, comm) }
    }
}
