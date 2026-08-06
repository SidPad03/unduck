import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.sigmanet.unduck", category: "Updater")

/// Lightweight self-updater against a Gitea release feed.
///
/// Why not Sparkle: Sparkle wants a Developer-ID-signed app + an EdDSA keypair +
/// an appcast, and its update artifact is a zipped .app, not a .pkg. For a
/// personal, ad-hoc-signed build distributed as a .pkg from a self-hosted Gitea,
/// that's more machinery than value. This hits Gitea's own releases API, compares
/// the tag to the running version, and hands the .pkg to the macOS Installer.
/// (If this ever goes public + notarized, switch to Sparkle - the appcast can
/// live on the same Gitea.)
@MainActor
final class Updater: ObservableObject {

    // Point these at your repo. Overridable via Info.plist (UnduckUpdateBase / Owner / Repo).
    private var apiBase: String { info("UnduckUpdateBase") ?? "https://git.sigmanet.com" }
    private var owner: String   { info("UnduckUpdateOwner") ?? "sid" }
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
                let (tag, pkgURL) = try await fetchLatest()
                latestVersion = tag
                if isNewer(tag, than: currentVersion), let pkgURL {
                    status = "Update available: \(tag)"
                    if interactive || promptedAutomatically() { offerInstall(tag: tag, pkg: pkgURL) }
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

    private func fetchLatest() async throws -> (tag: String, pkg: URL?) {
        let url = URL(string: "\(apiBase)/api/v1/repos/\(owner)/\(repo)/releases/latest")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Unduck", code: 1, userInfo: [NSLocalizedDescriptionKey: "Gitea returned a non-200 response"])
        }
        let release = try JSONDecoder().decode(GiteaRelease.self, from: data)
        let pkg = release.assets.first { $0.name.hasSuffix(".pkg") }?.browser_download_url
        return (release.tag_name, pkg.flatMap(URL.init(string:)))
    }

    private func offerInstall(tag: String, pkg: URL) {
        let a = NSAlert()
        a.messageText = "Update available: \(tag)"
        a.informativeText = "You have \(currentVersion). Download and install \(tag)? The macOS Installer will open."
        a.addButton(withTitle: "Download & Install")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        download(pkg)
    }

    private func download(_ pkg: URL) {
        busy = true
        status = "Downloading \(pkg.lastPathComponent)…"
        Task {
            defer { busy = false }
            do {
                let (tmp, _) = try await URLSession.shared.download(from: pkg)
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(pkg.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                status = "Opening installer…"
                NSWorkspace.shared.open(dest)   // launches the macOS Installer for the .pkg
            } catch {
                status = "Download failed"
                alert("Download failed", error.localizedDescription)
            }
        }
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

private struct GiteaRelease: Decodable {
    let tag_name: String
    let assets: [Asset]
    struct Asset: Decodable { let name: String; let browser_download_url: String }
}
