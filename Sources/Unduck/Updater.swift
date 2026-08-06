import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "Updater")

/// Self-updater against the GitHub Releases API.
///
/// The update is applied **in place**: download the DMG, mount it, stage the new
/// Unduck.app, then hand a small shell script the job of waiting for this process
/// to exit, swapping the bundle, and relaunching. From the user's side it is one
/// click and the app comes back on the new version.
///
/// It used to download the `.pkg` and open the macOS Installer, which meant a
/// five-step wizard and an admin prompt to update a menu-bar utility. The `.pkg`
/// is still published for fresh installs, and is still used as a fallback when a
/// release has no DMG or when the bundle can't be replaced without privileges.
///
/// Why not Sparkle: it wants a Developer-ID-signed app, an EdDSA keypair, and an
/// appcast. If Unduck ever goes notarized, switch to it.
@MainActor
final class Updater: ObservableObject {

    // Overridable via Info.plist (UnduckUpdateBase / Owner / Repo).
    private var apiBase: String { info("UnduckUpdateBase") ?? "https://api.github.com" }
    private var owner: String   { info("UnduckUpdateOwner") ?? "SidPad03" }
    private var repo: String    { info("UnduckUpdateRepo") ?? "unduck" }

    @Published var status: String = ""
    @Published var latestVersion: String?
    @Published var busy = false

    var currentVersion: String { info("CFBundleShortVersionString") ?? "0.0.0" }

    private func info(_ key: String) -> String? { Bundle.main.infoDictionary?[key] as? String }

    private struct Asset {
        let url: URL
        var isDMG: Bool { url.pathExtension.lowercased() == "dmg" }
    }

    /// `interactive == true` shows alerts (menu "Check for Updates…"); false is the
    /// quiet launch check that only speaks up when there's actually an update.
    func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        status = "Checking…"
        Task {
            defer { busy = false }
            do {
                let (tag, asset) = try await fetchLatest()
                latestVersion = tag
                if isNewer(tag, than: currentVersion), let asset {
                    status = "Update available: \(tag)"
                    offerInstall(tag: tag, asset: asset)
                } else {
                    status = "Up to date (\(currentVersion))"
                    if interactive { alert("You're up to date", "Unduck \(currentVersion) is the latest version.") }
                }
            } catch {
                status = "Update check failed"
                log.error("update check failed: \(error.localizedDescription, privacy: .public)")
                if interactive { alert("Couldn't check for updates", error.localizedDescription) }
            }
        }
    }

    private func fetchLatest() async throws -> (tag: String, asset: Asset?) {
        let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Unduck/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw err("No response from GitHub.") }
        switch http.statusCode {
        case 200: break
        case 404: throw err("This repository has no published releases yet.")
        case 403, 429: throw err("GitHub rate-limited the update check. Try again later.")
        default: throw err("GitHub returned HTTP \(http.statusCode).")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // Prefer the DMG: it carries the .app, which is what an in-place swap
        // needs. The .pkg is the fallback and goes through the Installer.
        let picked = release.assets.first { $0.name.hasSuffix(".dmg") }
            ?? release.assets.first { $0.name.hasSuffix(".pkg") }
        let assetURL = picked?.browser_download_url.flatMap(URL.init(string:))
        return (release.tag_name, assetURL.map(Asset.init))
    }

    private func offerInstall(tag: String, asset: Asset) {
        // An in-place swap needs write access to the folder holding the bundle.
        let inPlace = asset.isDMG && Self.canReplaceBundle()

        let a = NSAlert()
        a.messageText = "Update available: \(tag)"
        a.informativeText = inPlace
            ? "You have \(currentVersion). Unduck will download \(tag), replace itself, and restart."
            : "You have \(currentVersion). Download \(tag)? It will open so you can install it."
        a.addButton(withTitle: inPlace ? "Update & Restart" : "Download")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        if inPlace {
            selfUpdate(tag: tag, dmg: asset.url)
        } else {
            downloadAndOpen(asset.url)
        }
    }

    // MARK: in-place update

    private func selfUpdate(tag: String, dmg: URL) {
        busy = true
        status = "Downloading \(tag)…"
        let bundleURL = Bundle.main.bundleURL
        let expected = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))

        Task {
            defer { busy = false }
            do {
                let downloaded = try await downloadToTemp(dmg)
                status = "Installing \(tag)…"
                // Mounting, copying and verifying are all blocking work - keep
                // them off the main thread so the menu doesn't freeze.
                let staged = try await Task.detached(priority: .userInitiated) {
                    try Self.stageApp(fromDMG: downloaded, expectedVersion: expected)
                }.value

                try Self.launchSwapHelper(staged: staged, destination: bundleURL)
                status = "Restarting…"
                log.notice("self-update to \(tag, privacy: .public) staged; restarting")
                // Teardown runs on willTerminate, so the tap is released and media
                // un-mutes before the swap happens.
                NSApp.terminate(nil)
            } catch {
                status = "Update failed"
                log.error("self-update failed: \(error.localizedDescription, privacy: .public)")
                alert("Couldn't install the update",
                      "\(error.localizedDescription)\n\nYou can download it manually from the Releases page.")
            }
        }
    }

    private func downloadToTemp(_ url: URL) async throws -> URL {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw err("Download failed with HTTP \(http.statusCode).")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("unduck-update-\(UUID().uuidString)-\(url.lastPathComponent)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Can we replace our own bundle without asking for privileges? Replacing a
    /// bundle means writing into its parent directory. /Applications is normally
    /// group-writable by admins, so this is usually true.
    private nonisolated static func canReplaceBundle() -> Bool {
        let parent = Bundle.main.bundleURL.deletingLastPathComponent().path
        return FileManager.default.isWritableFile(atPath: parent)
    }

    /// Mount the DMG, copy Unduck.app out of it, verify it, unmount. Returns the
    /// staged copy. Runs off the main thread.
    private nonisolated static func stageApp(fromDMG dmg: URL, expectedVersion: String) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("unduck-stage-\(UUID().uuidString)")
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)

        // -mountpoint keeps this off /Volumes and out of the user's way; -nobrowse
        // stops it appearing in Finder.
        guard run("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path]) == 0 else {
            throw err("Could not open the downloaded disk image.")
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"])
            try? fm.removeItem(at: dmg)
        }

        let source = mount.appendingPathComponent("Unduck.app")
        guard fm.fileExists(atPath: source.path) else {
            throw err("The disk image didn't contain Unduck.app.")
        }

        let staged = work.appendingPathComponent("Unduck.app")
        // ditto, not cp: it preserves extended attributes and the code signature.
        guard run("/usr/bin/ditto", [source.path, staged.path]) == 0 else {
            throw err("Could not copy the new version out of the disk image.")
        }

        // Refuse to install something that isn't the version we were promised, or
        // whose signature is broken.
        let plist = staged.appendingPathComponent("Contents/Info.plist")
        let got = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? ""
        guard got == expectedVersion else {
            throw err("The download reported version \(got.isEmpty ? "unknown" : got), expected \(expectedVersion).")
        }
        guard run("/usr/bin/codesign", ["--verify", "--strict", staged.path]) == 0 else {
            throw err("The downloaded copy failed signature verification.")
        }
        return staged
    }

    /// Spawn the script that waits for us to quit, swaps the bundle and relaunches.
    /// It outlives this process - once the parent exits the child is reparented.
    private nonisolated static func launchSwapHelper(staged: URL, destination: URL) throws {
        let script = """
        #!/bin/sh
        # Written by Unduck's updater. Waits for the old process to exit, swaps the
        # bundle, and relaunches. Rolls back if the copy fails.
        PID="$1"; SRC="$2"; DEST="$3"
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 150 ]; do sleep 0.2; i=$((i+1)); done
        kill -0 "$PID" 2>/dev/null && { kill -TERM "$PID" 2>/dev/null; sleep 1; }

        BACKUP="${DEST}.old-$$"
        mv "$DEST" "$BACKUP" 2>/dev/null || exit 1
        if /usr/bin/ditto "$SRC" "$DEST"; then
            /bin/rm -rf "$BACKUP"
        else
            /bin/rm -rf "$DEST"
            mv "$BACKUP" "$DEST"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /bin/rm -rf "$(dirname "$SRC")"
        /usr/bin/open "$DEST"
        """
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("unduck-swap-\(UUID().uuidString).sh")
        try script.write(to: path, atomically: true, encoding: .utf8)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = [path.path, String(ProcessInfo.processInfo.processIdentifier),
                          staged.path, destination.path]
        try task.run()   // deliberately not waited on
    }

    // MARK: fallback (no DMG, or the bundle isn't ours to replace)

    private func downloadAndOpen(_ asset: URL) {
        busy = true
        status = "Downloading \(asset.lastPathComponent)…"
        Task {
            defer { busy = false }
            do {
                let dest = try await downloadToTemp(asset)
                status = "Opening…"
                NSWorkspace.shared.open(dest)   // .pkg -> Installer, .dmg -> mounts
            } catch {
                status = "Download failed"
                alert("Download failed", error.localizedDescription)
            }
        }
    }

    // MARK: helpers

    @discardableResult
    private nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }

    private func alert(_ title: String, _ body: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = body; a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true); a.runModal()
    }

    /// Numeric, dot-separated compare after stripping a leading v/V.
    private func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Shared by the main-actor and the detached staging code, so it lives at file scope.
private func err(_ message: String) -> NSError {
    NSError(domain: "Unduck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String? }
}
