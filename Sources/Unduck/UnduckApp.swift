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
                    AppearancePicker(selection: $model.appearance)
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

            // Observes the meter object, not the app model, so ten updates a
            // second redraw a 6pt bar instead of the entire popover.
            MeterSection(meter: model.meter, active: model.isActive)
        }
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

/// Level bar + limiter notice. Split out so the 10 Hz meter updates invalidate
/// only this subtree.
private struct MeterSection: View {
    @ObservedObject var meter: MeterModel
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(active ? Color.green.gradient : Color.secondary.gradient)
                        .frame(width: max(2, geo.size.width * meter.level))
                }
            }
            .frame(height: 6)

            if meter.limitingDB > 0.4 {
                Label("Limiting \(String(format: "%.0f", meter.limitingDB)) dB on loud content",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
    }
}

/// A hand-rolled segmented control.
///
/// SwiftUI's `.pickerStyle(.segmented)` bridges to `NSSegmentedControl`, which
/// hosts its SwiftUI labels in nested view graphs. Measuring it re-enters the
/// SwiftUI view graph *during* the outer layout pass, which re-registers
/// observation and re-dirties the graph - inside a `MenuBarExtra` window that
/// never reached a fixed point, so the run loop re-ran layout on every pass and
/// pinned a core. Plain buttons keep the appearance and stay entirely inside
/// SwiftUI's own layout, with no AppKit round-trip to re-enter through.
private struct AppearancePicker: View {
    @Binding var selection: AppModel.Appearance

    private struct Option: Identifiable {
        let id: AppModel.Appearance
        let title: String
    }

    private static let options = [
        Option(id: .menuBar, title: "Menu Bar"),
        Option(id: .dock, title: "Dock"),
        Option(id: .both, title: "Both"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.options) { option in
                let isSelected = selection == option.id
                Button {
                    if !isSelected { selection = option.id }
                } label: {
                    Text(option.title)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor)
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary))
    }
}
