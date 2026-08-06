// duckprobe - Unduck Phase 0 measurement tool (THROWAWAY).
//
// Purpose: answer the single go/no-go question for the whole Unduck project -
// can the FaceTime VoiceProcessingIO "duck" be defeated, and is it static or
// dynamic? This tool plays a 1 kHz test tone at a level you control (in dB,
// including deliberately ABOVE 0 dBFS to test whether Core Audio's float path
// survives the boost), and can instantiate its OWN VPIO to reproduce the duck
// locally without needing a call.
//
// This is a command-line tool on purpose: it builds with `swiftc` (no full
// Xcode needed) and is disposable. The real menu-bar app + Liquid Glass UI come
// AFTER Phase 0 says "go" and names a strategy.
//
// Build:  bash phase0/build.sh     Run: ./phase0/duckprobe
// See phase0/README.md for the exact call protocol and what to listen for.

import Foundation
import AVFoundation
import AudioToolbox

// ── Shared audio-thread state ────────────────────────────────────────────────
// Plain heap Int32/Double pointers, allocated once for the process lifetime.
// Naturally-aligned scalar loads/stores are atomic on arm64, and this is a
// throwaway probe (no memory-ordering subtleties matter for gain params), so
// this avoids both an ARC/allocation on the render thread and any Swift 6
// concurrency friction from capturing mutable vars. The render closure captures
// only these `let` pointers + Double constants (all Sendable) and never touches
// the Swift/ObjC runtime.
let gainCentibels = UnsafeMutablePointer<Int32>.allocate(capacity: 1)   // extra gain, dB×100
let baseCentibels = UnsafeMutablePointer<Int32>.allocate(capacity: 1)   // baseline level, dBFS×100
let toneFlag      = UnsafeMutablePointer<Int32>.allocate(capacity: 1)   // 1 = emit tone, 0 = silence
let phasePtr      = UnsafeMutablePointer<Double>.allocate(capacity: 1)  // sine phase, persists across calls

let toneHz        = 1000.0
let sampleRate    = 48000.0

// Baseline levels the `b` command cycles through (dBFS).
let baselineChoicesCentibels: [Int32] = [-1200, -600, -100]   // -12, -6, -1 dBFS

func setup() {
    gainCentibels.initialize(to: 0)
    baseCentibels.initialize(to: baselineChoicesCentibels[0])
    toneFlag.initialize(to: 1)          // start with the tone ON so you hear it immediately
    phasePtr.initialize(to: 0)
}

// ── Tone engine ──────────────────────────────────────────────────────────────
func makeToneEngine() -> AVAudioEngine {
    let engine = AVAudioEngine()
    let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    let inc = 2.0 * Double.pi * toneHz / sampleRate

    let src = AVAudioSourceNode(format: fmt) { isSilence, _, frameCount, ablPtr -> OSStatus in
        let emit = toneFlag.pointee != 0
        if !emit {
            isSilence.pointee = ObjCBool(true)
        }
        let baseDB = Double(baseCentibels.pointee) / 100.0
        let extraDB = Double(gainCentibels.pointee) / 100.0
        // Linear amplitude. Deliberately allowed to exceed 1.0 - that IS the
        // test: does the boosted-above-0-dBFS float sample survive to the point
        // where the system duck attenuates it back down?
        let amp = emit ? pow(10.0, (baseDB + extraDB) / 20.0) : 0.0

        var phase = phasePtr.pointee
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        let n = Int(frameCount)
        var frame = 0
        while frame < n {
            let s = Float(amp * sin(phase))
            phase += inc
            if phase >= 2.0 * Double.pi { phase -= 2.0 * Double.pi }
            for buffer in abl {
                let p = buffer.mData!.assumingMemoryBound(to: Float.self)
                p[frame] = s
            }
            frame += 1
        }
        phasePtr.pointee = phase
        return noErr
    }

    engine.attach(src)
    engine.connect(src, to: engine.mainMixerNode, format: fmt)
    // mainMixerNode auto-connects to outputNode. outputVolume stays 1.0 so the
    // >1.0 float samples pass through unclamped by us.
    return engine
}

// ── Self-VPIO (reproduce the duck locally, no call needed) ───────────────────
// Instantiating a VoiceProcessingIO unit anywhere in the process makes macOS
// duck all "other audio" - including our tone from the separate engine above.
// This opens the microphone (expect a TCC prompt the first time).
var vpioEngine: AVAudioEngine? = nil

func startSelfVPIO() {
    if vpioEngine != nil { print("  [self-VPIO already engaged]"); return }
    let e = AVAudioEngine()
    do {
        try e.inputNode.setVoiceProcessingEnabled(true)   // engage VPIO + open mic
        // Keep the graph pulling the input so VPIO stays active, but route it to
        // the mixer at zero volume so we don't echo the mic to the speakers.
        let inFmt = e.inputNode.outputFormat(forBus: 0)
        e.connect(e.inputNode, to: e.mainMixerNode, format: inFmt)
        e.mainMixerNode.outputVolume = 0
        e.prepare()
        try e.start()
        vpioEngine = e
        print("  [self-VPIO ENGAGED] mic is open; the tone should now DUCK (get quieter).")
        print("  -> Boost gain with '+' until the tone is back to its original loudness.")
        print("     The number of dB you added ≈ the duck depth. Then 'v' again to release")
        print("     and notice how abruptly the level jumps back (the release-transient risk).")
    } catch {
        print("  [self-VPIO FAILED] \(error.localizedDescription)")
        print("  (If this is a mic-permission denial: allow mic access for your terminal in")
        print("   System Settings > Privacy & Security > Microphone, then try 'v' again.")
        print("   You can also just skip this and do the real FaceTime test instead.)")
    }
}

func stopSelfVPIO() {
    guard let e = vpioEngine else { print("  [self-VPIO not engaged]"); return }
    e.stop()
    try? e.inputNode.setVoiceProcessingEnabled(false)
    vpioEngine = nil
    print("  [self-VPIO RELEASED] duck should lift; tone jumps back up.")
}

// ── UI (terminal) ────────────────────────────────────────────────────────────
func currentGainDB() -> Double { Double(gainCentibels.pointee) / 100.0 }
func currentBaseDB() -> Double { Double(baseCentibels.pointee) / 100.0 }

func clampExtra(_ centibels: Int32) -> Int32 { max(-4800, min(4800, centibels)) }  // ±48 dB

func printStatus() {
    let base = currentBaseDB()
    let extra = currentGainDB()
    let composite = base + extra
    let mult = pow(10.0, extra / 20.0)
    print(String(format: "  tone: %@   baseline: %.0f dBFS   extra gain: %+.1f dB (×%.2f)   composite source: %+.1f dBFS%@",
                 toneFlag.pointee != 0 ? "ON" : "off",
                 base, extra, mult, composite,
                 composite > 0 ? "  ⚠ ABOVE 0 dBFS - float-path/clipping test" : ""))
    print(String(format: "  self-VPIO: %@", vpioEngine != nil ? "ENGAGED (duck active)" : "off"))
}

func printHelp() {
    print("""

    ── duckprobe commands ─────────────────────────────────────────────
      t          toggle the test tone on/off
      +  / -     nudge gain by ±1 dB
      +N / -N    nudge gain by ±N dB   (e.g. +6, -3)
      g <dB>     set extra gain to an absolute value (e.g. g 20)
      0          reset extra gain to 0 dB
      b          cycle baseline level  (-12 → -6 → -1 dBFS)  [headroom probe]
      v          toggle self-VPIO - reproduce the duck locally (opens mic)
      s          status
      h          help
      q          quit (stops audio cleanly)
    ────────────────────────────────────────────────────────────────────
    """)
}

func handle(_ raw: String) {
    let line = raw.trimmingCharacters(in: .whitespaces)
    if line.isEmpty { return }
    switch line.lowercased() {
    case "q", "quit", "exit":
        exitCleanly()
    case "t":
        toneFlag.pointee = toneFlag.pointee != 0 ? 0 : 1
        printStatus()
    case "0":
        gainCentibels.pointee = 0; printStatus()
    case "b":
        let cur = baseCentibels.pointee
        let idx = baselineChoicesCentibels.firstIndex(of: cur) ?? 0
        baseCentibels.pointee = baselineChoicesCentibels[(idx + 1) % baselineChoicesCentibels.count]
        printStatus()
    case "v":
        if vpioEngine == nil { startSelfVPIO() } else { stopSelfVPIO() }
        printStatus()
    case "s", "status":
        printStatus()
    case "h", "help", "?":
        printHelp()
    case "+":
        gainCentibels.pointee = clampExtra(gainCentibels.pointee + 100); printStatus()
    case "-":
        gainCentibels.pointee = clampExtra(gainCentibels.pointee - 100); printStatus()
    default:
        if line.hasPrefix("g ") {
            if let db = Double(line.dropFirst(2).trimmingCharacters(in: .whitespaces)) {
                gainCentibels.pointee = clampExtra(Int32((db * 100).rounded())); printStatus()
            } else { print("  ? couldn't parse a dB value. Try: g 20") }
        } else if (line.hasPrefix("+") || line.hasPrefix("-")), let db = Double(line) {
            gainCentibels.pointee = clampExtra(gainCentibels.pointee + Int32((db * 100).rounded())); printStatus()
        } else {
            print("  ? unknown command '\(line)' - 'h' for help")
        }
    }
}

var toneEngine: AVAudioEngine!

func exitCleanly() {
    if vpioEngine != nil { stopSelfVPIO() }
    toneEngine?.stop()
    print("  bye - audio stopped.")
    exit(0)
}

// ── main ─────────────────────────────────────────────────────────────────────
setup()
toneEngine = makeToneEngine()
do {
    try toneEngine.start()
} catch {
    FileHandle.standardError.write(Data("FATAL: could not start audio engine: \(error)\n".utf8))
    exit(1)
}

print("""
╭──────────────────────────────────────────────────────────────────────╮
│  duckprobe - Unduck Phase 0 go/no-go tool                             │
╰──────────────────────────────────────────────────────────────────────╯
A 1 kHz tone is now playing. Two ways to test the FaceTime duck:

  A) LOCAL, no call:  press 'v' to run our own VoiceProcessingIO. The tone
     should get quieter (that's the same duck FaceTime causes). Boost with '+'
     until it's restored - the dB you added ≈ the duck depth. Press 'v' again
     to release and notice the abrupt jump back up.

  B) REAL, with your friend:  start a FaceTime call, keep this tone playing,
     and (1) note how much it ducks, (2) boost until restored, (3) have your
     friend ALTERNATE talking and staying silent while you listen to the steady
     tone. If the tone stays flat → STATIC duck → the project is a GO. If it
     dips more when they talk → DYNAMIC duck → stop and reassess.

Press 'h' for commands, 's' for status, 'q' to quit.
""")
printStatus()

while let line = readLine(strippingNewline: true) {
    handle(line)
}
// EOF (e.g. piped input ended or Ctrl-D) - clean up.
exitCleanly()
