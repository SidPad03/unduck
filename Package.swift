// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unduck",
    platforms: [.macOS(.v15)],   // compile floor; the app runtime-gates real routing at 26.1 (see spec §3.4)
    targets: [
        // Realtime DSP core in C — no ARC, no allocation, no Swift runtime on the audio thread.
        .target(
            name: "CUnduckRender"
        ),
        // The menu-bar app.
        .executableTarget(
            name: "Unduck",
            dependencies: ["CUnduckRender"]
        ),
        // Buffer-list geometry + the DSP core: the parts that can be checked
        // without a live call, against the device layouts that actually ship.
        .testTarget(
            name: "UnduckTests",
            dependencies: ["Unduck", "CUnduckRender"]
        ),
    ],
    swiftLanguageModes: [.v5]   // pragmatic: this app captures raw pointers in the
                                // IOProc block; v5 mode avoids a wall of Sendable
                                // annotations without changing runtime behavior.
)
