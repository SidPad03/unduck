import Foundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "CallDetector")

/// Detects an active call by watching whether any communication process has its
/// mic running (`kAudioProcessPropertyIsRunningInput`). A 1 to 4 Hz poll is used
/// instead of HAL property listeners because listeners are known to miss
/// transitions (spec section 5.1); polling is simple and never gets stuck.
/// Debounced so transient mic blips do not flap the audio graph.
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

    private var timer: DispatchSourceTimer?
    private var trueStreak = 0
    private var falseStreak = 0
    private var reportedActive = false

    /// (callActive, communicationProcessObjectIDs). Delivered on the main queue.
    var onChange: ((Bool, [AudioObjectID]) -> Void)?

    init(commBundleIDs: Set<String> = CallDetector.defaultCommBundleIDs) {
        self.commBundleIDs = commBundleIDs
    }

    func start() {
        stop()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
        log.info("call detector started (\(self.commBundleIDs.joined(separator: ","), privacy: .public))")
    }

    func stop() { timer?.cancel(); timer = nil }

    /// The communication processes active right now (used by manual activation).
    func currentCommProcesses() -> [AudioObjectID] {
        CA.processObjects.filter { obj in
            guard let bid = CA.bundleID(ofProcess: obj) else { return false }
            return commBundleIDs.contains(bid)
        }
    }

    private func poll() {
        var commObjects: [AudioObjectID] = []
        var anyInput = false
        for process in CA.processObjects {
            guard let bid = CA.bundleID(ofProcess: process), commBundleIDs.contains(bid) else { continue }
            commObjects.append(process)
            if CA.isRunningInput(process) { anyInput = true }
        }

        if anyInput { trueStreak += 1; falseStreak = 0 } else { falseStreak += 1; trueStreak = 0 }

        if !reportedActive, trueStreak >= activateAfter {
            reportedActive = true
            log.info("call ACTIVE")
            onChange?(true, commObjects)
        } else if reportedActive, falseStreak >= deactivateAfter {
            reportedActive = false
            log.info("call ENDED")
            onChange?(false, [])
        } else if reportedActive {
            // Still active: keep the comm-process set fresh (PIDs can change).
            onChange?(true, commObjects)
        }
    }
}
