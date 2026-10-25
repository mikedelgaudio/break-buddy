import AppKit
import SwiftUI

/// Shows the full-screen break overlay on every display whenever the model has an overlay
/// phase (prompt → countdown → done), and removes it when the phase clears.
final class BreakOverlayController {
    private let model: AppModel
    private var windows: [OverlayWindow] = []

    init(model: AppModel) {
        self.model = model
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = model.overlayPhase
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
        update()
    }

    private func update() {
        if model.overlayPhase != nil { show() } else { hide() }
    }

    private func show() {
        guard windows.isEmpty else { return }
        let mouse = NSEvent.mouseLocation
        let primary = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen, model: model, primary: screen == primary)
            window.alphaValue = 0
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate()
        windows.first { $0.isPrimary }?.makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            for window in windows { window.animator().alphaValue = 1 }
        }
    }

    private func hide() {
        guard !windows.isEmpty else { return }
        let closing = windows
        windows = []
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            for window in closing { window.animator().alphaValue = 0 }
        } completionHandler: {
            MainActor.assumeIsolated {
                for window in closing { window.orderOut(nil) }
            }
        }
    }

    /// For the E2E harness: the real windows currently on screen.
    var windowSummaries: [[String: Any]] {
        windows.map { window in
            [
                "visible": window.isVisible,
                "primary": window.isPrimary,
                "coversScreen": window.frame == window.screenFrame,
                "aboveFullScreenApps": window.level.rawValue >= NSWindow.Level.screenSaver.rawValue,
                "allSpaces": window.collectionBehavior.contains(.canJoinAllSpaces),
            ]
        }
    }
}

final class OverlayWindow: NSWindow {
    let isPrimary: Bool
    let screenFrame: NSRect
    private let model: AppModel
    private let shownAt = Date()

    init(screen: NSScreen, model: AppModel, primary: Bool) {
        self.isPrimary = primary
        self.screenFrame = screen.frame
        self.model = model
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        setFrame(screen.frame, display: false)

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        let host = NSHostingView(rootView: BreakOverlayView(model: model, primary: primary))
        host.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            host.topAnchor.constraint(equalTo: blur.topAnchor),
            host.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        contentView = blur
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Esc skips whatever is showing. Ignored for the first second so a keystroke already in
    /// flight when the overlay appears doesn't dismiss it.
    override func cancelOperation(_ sender: Any?) {
        guard Date().timeIntervalSince(shownAt) > 1 else { return }
        BreakOverlayView.escape(model)
    }
}

// MARK: - SwiftUI

struct BreakOverlayView: View {
    let model: AppModel
    let primary: Bool
    /// Rendering offscreen (E2E) has no window blur, so paint a stand-in backdrop.
    var renderBackdrop = false

    static let mint = Color(red: 0.42, green: 0.83, blue: 0.69)
    static let teal = Color(red: 0.16, green: 0.56, blue: 0.53)

    static func escape(_ model: AppModel) {
        switch model.overlayPhase {
        case .prompt: model.skipPrompt()
        case .breaking: model.endBreakEarly()
        case .finished: model.dismissFinished()
        case nil: break
        }
    }

    var body: some View {
        ZStack {
            if renderBackdrop {
                LinearGradient(colors: [Color(red: 0.08, green: 0.16, blue: 0.17), Color(red: 0.05, green: 0.08, blue: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            Color.black.opacity(0.28)
            if let phase = model.overlayPhase {
                if primary { MainCard(model: model, phase: phase) } else { CompactCard(model: model, phase: phase) }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

private struct MainCard: View {
    let model: AppModel
    let phase: OverlayPhase

    var body: some View {
        let copy = OverlayCopy(phase: phase, settings: model.settings)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                Text("Break Buddy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.bottom, 44)

            CountdownRing(model: model, phase: phase)
                .frame(width: 248, height: 248)
                .padding(.bottom, 40)

            Text(copy.headline)
                .font(.system(size: 46, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.bottom, 12)
            Text(copy.subtitle)
                .font(.system(size: 19))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 640)
                // Fixed height (two lines) so nothing shifts between prompt, countdown and done.
                .frame(height: 52, alignment: .top)
                .padding(.bottom, 32)

            Buttons(model: model, phase: phase)

            Text(copy.footnote)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 22)
        }
        .padding(48)
    }
}

private struct CompactCard: View {
    let model: AppModel
    let phase: OverlayPhase

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            Text(OverlayCopy(phase: phase, settings: model.settings).headline)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            if case .breaking(let active) = phase {
                Text(OverlayCopy.clock(active.endsAt.timeIntervalSince(model.now)))
                    .font(.system(size: 40, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

private struct CountdownRing: View {
    let model: AppModel
    let phase: OverlayPhase

    var body: some View {
        let (progress, center, caption) = state
        ZStack {
            Circle()
                .stroke(.white.opacity(0.1), lineWidth: 14)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    AngularGradient(colors: [BreakOverlayView.teal, BreakOverlayView.mint, BreakOverlayView.teal], center: .center),
                    style: StrokeStyle(lineWidth: 14, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: progress)
            VStack(spacing: 6) {
                center
                if let caption {
                    Text(caption)
                        .font(.system(size: 14, weight: .medium))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
    }

    private var state: (Double, AnyView, String?) {
        switch phase {
        case .prompt(let prompt):
            let icon = AnyView(Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112))
            guard let start = prompt.autoStartAt else { return (0, icon, nil) }
            let left = max(0, start.timeIntervalSince(model.now))
            return (1 - left / AppModel.promptAutoStart, icon, "Starts in \(Int(left.rounded(.up)))s")
        case .breaking(let active):
            let total = max(1, active.kinds.map(model.settings.duration).max() ?? 1)
            let left = max(0, active.endsAt.timeIntervalSince(model.now))
            let clock = Text(OverlayCopy.clock(left))
                .font(.system(size: 68, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            return (left / total, AnyView(clock), "remaining")
        case .finished:
            let check = Image(systemName: "checkmark")
                .font(.system(size: 76, weight: .semibold))
                .foregroundStyle(BreakOverlayView.mint)
            return (1, AnyView(check), nil)
        }
    }
}

private struct Buttons: View {
    let model: AppModel
    let phase: OverlayPhase

    var body: some View {
        HStack(spacing: 14) {
            switch phase {
            case .prompt(let prompt):
                PillButton(title: "Start \(OverlayCopy.length(prompt.kinds, model.settings)) break", style: .primary) { model.startPromptedBreak() }
                PillButton(title: "Snooze \(Int(model.settings.snoozeMinutes)) min", style: .secondary) { model.snooze() }
                PillButton(title: "Skip", style: .plain) { model.skipPrompt() }
            case .breaking:
                PillButton(title: "End break early", style: .secondary) { model.endBreakEarly() }
            case .finished:
                PillButton(title: "Back to work", style: .primary) { model.dismissFinished() }
            }
        }
    }
}

private struct PillButton: View {
    enum Style { case primary, secondary, plain }

    let title: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: style == .primary ? .semibold : .medium))
                .foregroundStyle(style == .primary ? Color.black.opacity(0.85) : .white.opacity(style == .plain ? 0.65 : 0.92))
                .padding(.horizontal, style == .plain ? 14 : 26)
                .padding(.vertical, 13)
                .background {
                    switch style {
                    case .primary: Capsule().fill(BreakOverlayView.mint)
                    case .secondary: Capsule().fill(.white.opacity(0.14))
                    case .plain: Color.clear
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// All overlay wording in one place.
struct OverlayCopy {
    let headline: String
    let subtitle: String
    let footnote: String

    init(phase: OverlayPhase, settings: BreakSettings) {
        switch phase {
        case .prompt(let prompt):
            if prompt.catchUp {
                headline = "Your meeting is over"
                subtitle = prompt.kinds.contains(.move)
                    ? "Take a moment to stand, move, and rest your eyes."
                    : "Take a moment to rest your eyes."
            } else {
                (headline, subtitle) = Self.instruction(prompt.kinds)
            }
            footnote = prompt.autoStartAt == nil ? "Press Esc to skip" : "The break starts by itself · Press Esc to skip"
        case .breaking(let active):
            (headline, subtitle) = Self.instruction(active.kinds)
            footnote = "Press Esc to end early"
        case .finished(let kinds):
            headline = "Nice break"
            let timers = kinds.sorted().map { $0 == .eye ? "eye" : "movement" }.joined(separator: " and ")
            subtitle = "Your \(timers) timer\(kinds.count > 1 ? "s have" : " has") restarted."
            footnote = " "
        }
    }

    private static func instruction(_ kinds: Set<BreakKind>) -> (String, String) {
        switch kinds {
        case [.eye]: ("Rest your eyes", "Look at something about 20 feet (6 m) away and let your eyes relax.")
        case [.move]: ("Stand up and move", "Stretch, walk around, or grab some water.")
        default: ("Time for a break", "Stand up, stretch, and look into the distance.")
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func length(_ kinds: Set<BreakKind>, _ settings: BreakSettings) -> String {
        let seconds = Int(kinds.map(settings.duration).max() ?? 0)
        return seconds < 60 || seconds % 60 != 0 ? "\(seconds)-second" : "\(seconds / 60)-minute"
    }
}
