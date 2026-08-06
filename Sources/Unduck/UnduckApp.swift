import SwiftUI
import AppKit

@main
struct UnduckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // The menu-bar icon is hidden in Dock-only mode.
        MenuBarExtra(isInserted: Binding(get: { model.appearance != .dock }, set: { _ in })) {
            PopoverView().environmentObject(model)
        } label: {
            // Filled duck while routing, outline duck when idle.
            Image(nsImage: model.isActive ? DuckIcon.filled : DuckIcon.outline)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.applyAppearance()
    }
    // Clicking the Dock icon (Dock-only / Both modes) opens the controls window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppModel.shared.showControls()
        return true
    }
}

/// The menu-bar icon: a duck silhouette drawn as a template image so it tints
/// itself for light and dark menu bars. Filled = active, outline = inactive.
enum DuckIcon {
    static let filled: NSImage = make(filled: true)
    static let outline: NSImage = make(filled: false)

    private static let center = CGPoint(x: 9.0, y: 8.0)

    private static func make(filled: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 17), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            drawDuck(ctx, scale: 1.0)                                   // solid silhouette
            if filled {
                ctx.setBlendMode(.clear); dot(ctx, 14.0, 11.0, 1.0); ctx.setBlendMode(.normal)   // eye hole
            } else {
                ctx.setBlendMode(.clear); drawDuck(ctx, scale: 0.80); ctx.setBlendMode(.normal)  // hollow it out
                ctx.setFillColor(NSColor.black.cgColor); dot(ctx, 14.0, 11.0, 0.9)               // eye dot
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func scaled(_ p: CGPoint, _ f: CGFloat) -> CGPoint {
        CGPoint(x: center.x + (p.x - center.x) * f, y: center.y + (p.y - center.y) * f)
    }

    private static func dot(_ ctx: CGContext, _ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
        ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)); ctx.fillPath()
    }

    /// Draw the duck, uniformly shrunk toward its center by `f` (1.0 = full size).
    private static func drawDuck(_ ctx: CGContext, scale f: CGFloat) {
        func ell(_ cx: CGFloat, _ cy: CGFloat, _ rx: CGFloat, _ ry: CGFloat) {
            let c = scaled(CGPoint(x: cx, y: cy), f)
            ctx.addEllipse(in: CGRect(x: c.x - rx * f, y: c.y - ry * f, width: rx * f * 2, height: ry * f * 2)); ctx.fillPath()
        }
        func tri(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            ctx.beginPath(); ctx.move(to: scaled(a, f)); ctx.addLine(to: scaled(b, f)); ctx.addLine(to: scaled(c, f)); ctx.closePath(); ctx.fillPath()
        }
        ell(8.5, 7.0, 6.0, 4.6)                                                              // body
        ell(13.2, 10.3, 3.8, 3.8)                                                            // head
        tri(CGPoint(x: 3.4, y: 7.4), CGPoint(x: 0.8, y: 9.3), CGPoint(x: 3.7, y: 8.9))       // tail
        tri(CGPoint(x: 16.3, y: 10.7), CGPoint(x: 19.6, y: 9.9), CGPoint(x: 16.3, y: 8.6))   // beak
    }
}

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if case .unsupportedOS = model.state {
                banner("This Mac needs macOS 26.1 or later for reliable routing.", .orange)
            }
            if case .error(let msg) = model.state {
                banner(msg, .red)
            }

            mediaControl

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(get: { model.isActive }, set: { model.setManual($0) })) { Text("Unduck now") }
                    .help("Turn the media boost on or off by hand. Overrides auto for this call.")
                Toggle("Activate automatically on calls", isOn: $model.autoActivate)
                Toggle("Launch at login", isOn: $model.launchAtLogin)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Show Unduck in").font(.caption).foregroundStyle(.secondary)
                    Picker("Show Unduck in", selection: $model.appearance) {
                        Text("Menu Bar").tag(AppModel.Appearance.menuBar)
                        Text("Dock").tag(AppModel.Appearance.dock)
                        Text("Both").tag(AppModel.Appearance.both)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                .padding(.top, 2)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .background(.ultraThinMaterial)   // Liquid Glass on macOS 26
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unduck").font(.headline)
                Text(model.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Image(systemName: model.menuBarSymbol).foregroundStyle(.secondary)
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .active: return .green
        case .error, .unsupportedOS: return .orange
        default: return .secondary
        }
    }

    private var mediaControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Slider(value: $model.boostDB, in: 0...30, step: 1)
                Text("\(Int(model.boostDB)) dB")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }

            meter

            if model.limitingDB > 0.4 {
                Label("Limiting \(String(format: "%.0f", model.limitingDB)) dB on loud content",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }

    private var meter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(model.isActive ? Color.green.gradient : Color.secondary.gradient)
                    .frame(width: max(2, geo.size.width * model.meterLevel))
            }
        }
        .frame(height: 6)
    }

    private var footer: some View {
        HStack {
            Text("v\(model.updater.currentVersion)").font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Button("Check for Updates") { model.updater.check(interactive: true) }.controlSize(.small)
            Button("Quit") { model.shutDown(); NSApplication.shared.terminate(nil) }.controlSize(.small)
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            Text(text).font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
