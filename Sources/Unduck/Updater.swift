import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "Updater")

/// Lightweight self-updater against the GitHub Releases API.
///
/// Releases are published by `.github/workflows/release.yml`, which builds on a
/// macOS runner and attaches both a `.pkg` and a `.dmg` to the tag's release.
/// This reads the newest release, compares its tag to the running version, and
/// hands the `.pkg` to the macOS Installer (falling back to the `.dmg` if no
/// `.pkg` is attached).
///
/// Why not Sparkle: Sparkle wants a Developer-ID-signed app + an EdDSA keypair +
/// an appcast, and its update artifact is a zipped .app, not a .pkg. For an
/// ad-hoc-signed build published as release assets, that's more machinery than
/// value. If Unduck ever goes notarized, switch to Sparkle.
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

    /// `interactive == true` shows alerts (menu "Check for Updates…"); false is the
    /// quiet launch/daily check that only speaks up when there's actually an update.
    func check(interactive: Bool) {
        guard !busy else { return }
        busy = true
        status = "Checking…"
        Task {
            defer { busy = false }
            do {
                let (tag, assetURL) = try await fetchLatest()
                latestVersion = tag
                if isNewer(tag, than: currentVersion), let assetURL {
                    status = "Update available: \(tag)"
                    if interactive || promptedAutomatically() { offerInstall(tag: tag, asset: assetURL) }
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

    private func promptedAutomatically() -> Bool { true } // auto-check still offers, just non-nagging

    private func fetchLatest() async throws -> (tag: String, asset: URL?) {
        let url = URL(string: "\(apiBase)/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Unduck/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw updateError("No response from GitHub.")
        }
        switch http.statusCode {
        case 200: break
        case 404:
            // No published release yet - not an error worth alarming the user about.
            throw updateError("This repository has no published releases yet.")
        case 403, 429:
            throw updateError("GitHub rate-limited the update check. Try again later.")
        default:
            throw updateError("GitHub returned HTTP \(http.statusCode).")
        }

        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        // Prefer the .pkg: it installs in one click. The .dmg is the human-facing
        // download and only gets used if no .pkg was attached.
        let asset = release.assets.first { $0.name.hasSuffix(".pkg") }
            ?? release.assets.first { $0.name.hasSuffix(".dmg") }
        return (release.tag_name, asset?.browser_download_url.flatMap(URL.init(string:)))
    }

    private func offerInstall(tag: String, asset: URL) {
        let isPkg = asset.pathExtension.lowercased() == "pkg"
        let a = NSAlert()
        a.messageText = "Update available: \(tag)"
        a.informativeText = isPkg
            ? "You have \(currentVersion). Download and install \(tag)? The macOS Installer will open."
            : "You have \(currentVersion). Download \(tag)? The disk image will open - drag Unduck into Applications."
        a.addButton(withTitle: isPkg ? "Download & Install" : "Download")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        download(asset)
    }

    private func download(_ asset: URL) {
        busy = true
        status = "Downloading \(asset.lastPathComponent)…"
        Task {
            defer { busy = false }
            do {
                let (tmp, response) = try await URLSession.shared.download(from: asset)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw updateError("Download failed with HTTP \(http.statusCode).")
                }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(asset.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                status = "Opening installer…"
                NSWorkspace.shared.open(dest)   // .pkg -> Installer, .dmg -> mounts
            } catch {
                status = "Download failed"
                alert("Download failed", error.localizedDescription)
            }
        }
    }

    private func updateError(_ message: String) -> NSError {
        NSError(domain: "Unduck", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
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

private struct GitHubRelease: Decodable {
    let tag_name: String
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String? }
}
