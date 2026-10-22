import SwiftUI

/// The welcome on first launch: the bear walks the user through setup.
struct OnboardingView: View {
    @StateObject private var model: OnboardingModel
    @Environment(\.dismissWindow) private var dismissWindow

    init(accessibility: AccessibilityService, core: FloeCore, configManager: ConfigManager) {
        _model = StateObject(wrappedValue: OnboardingModel(
            accessibility: accessibility, core: core, configManager: configManager
        ))
    }

    init(model: OnboardingModel) {
        _model = StateObject(wrappedValue: model)
    }

    private var stepIndex: Int { model.steps.firstIndex(of: model.step) ?? 0 }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.leading, 56)

                stage
                    .padding(.top, 20)

                SpeechBox { Text(bubble) }
                    .id(bubble)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                    .padding(.top, 22)
                    .padding(.trailing, Palette.shadow)

                content
                    .id(model.step)
                    .transition(.asymmetric(
                        insertion: .offset(x: 40).combined(with: .opacity),
                        removal: .offset(x: -40).combined(with: .opacity)
                    ))
                    .padding(.top, 18)
                    .padding(.trailing, Palette.shadow)

                Spacer(minLength: 12)

                buttons
                    .padding(.trailing, Palette.shadow)
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)

            Confetti(trigger: model.confetti)
        }
        .frame(width: 520, height: 700)
        .environment(\.colorScheme, .light)
        .animation(.easeOut(duration: 0.3), value: model.step)
        .animation(.easeOut(duration: 0.25), value: bubble)
        .animation(.easeOut(duration: 0.25), value: model.issues)
        .background(WindowConfigurator(floating: floating))
    }

    /// Floe starts tiling right away and raises the windows it arranges, so
    /// the welcome stays on top. It steps back while the user works in
    /// System Settings, so it doesn't cover the list they need.
    private var floating: Bool {
        switch model.step {
        case .accessibility: !model.waitingForAccess
        case .checks: model.issues.isEmpty
        default: true
        }
    }

    // MARK: - Header and stage

    private var header: some View {
        HStack(spacing: 14) {
            Text("FLOE")
                .font(.label(12, weight: .heavy))
                .kerning(3)
                .foregroundStyle(Palette.ink)
            StepMeter(index: stepIndex, count: model.steps.count)
        }
        .frame(height: 22)
    }

    private var stage: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Palette.ink)
            BearView(clip: model.bear)
                .frame(width: stageHeight - 4, height: stageHeight - 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            Text(stageTitle)
                .font(.label(10, weight: .bold))
                .kerning(1.5)
                .foregroundStyle(.white.opacity(0.75))
                .padding(12)
        }
        .frame(height: stageHeight)
        .clipped()
    }

    /// The cheat sheet needs the room, so the bear steps back for it.
    private var stageHeight: CGFloat {
        switch model.step {
        case .done: 150
        case .checks where model.issues.count > 1: 200
        default: 240
        }
    }

    private var stageTitle: String {
        let name = switch model.step {
        case .welcome: "HELLO"
        case .accessibility: "ACCESS"
        case .checks: "CHECKS"
        case .desktops: "DESKTOPS"
        case .practice: "PRACTICE"
        case .apps: "APPS"
        case .done: "READY"
        }
        return String(format: "%02d — ", stepIndex + 1) + name
    }

    // MARK: - What the bear says

    private var bubble: String {
        switch model.step {
        case .welcome:
            "Hi, I'm Floe's polar bear. Let's get your windows in order. It only takes a minute."
        case .accessibility:
            if model.justGranted {
                "That worked. Now I can move your windows."
            } else if model.waitingForAccess {
                "Find Floe in the list and switch it on. I'll wait right here."
            } else {
                "First, macOS has to let me move your windows. Click below and switch Floe on."
            }
        case .checks:
            model.issues.isEmpty
                ? "All fixed. Nothing's in my way now."
                : "A few things on your Mac get in my way. Let's sort them out."
        case .desktops:
            switch model.desktopSetup {
            case .offer: "You have just one desktop. Can I set up a few so you can try switching?"
            case .working: "Setting up your desktops. Mission Control opens for a moment."
            case .failed: "Hmm, that didn't work. You can add desktops in Mission Control any time."
            }
        case .practice:
            switch model.practice {
            case .goThere: "Now you try. Press \(model.practiceKeys?.there ?? "") to jump to desktop 2."
            case .comeBack: "Whoosh. Now press \(model.practiceKeys?.back ?? "") to come back."
            case .finished: "Perfect. You're a natural."
            }
        case .apps:
            switch model.appSwitch {
            case .offer: "One more trick. Hold fn and press a letter to jump straight to an app."
            case .jump: "Try it. Press fn \(model.finderKey) to jump to Finder."
            case .pull: "Nice. Now click a window of another app and press fn shift \(model.finderKey). Finder's window comes over to you."
            case .finished: "That's the app switcher. Pick a letter for every app in Settings."
            }
        case .done:
            "All set. I live in your menu bar now."
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .welcome: welcomeContent
        case .accessibility: accessibilityContent
        case .checks: checksContent
        case .desktops: desktopsContent
        case .practice: practiceContent
        case .apps: appsContent
        case .done: doneContent
        }
    }

    private var welcomeContent: some View {
        HStack(spacing: 0) {
            FeatureCell(number: "01", text: "Tiles your windows")
            Rectangle().fill(Palette.rule).frame(width: Palette.line)
            FeatureCell(number: "02", text: "Jumps between desktops")
            Rectangle().fill(Palette.rule).frame(width: Palette.line)
            FeatureCell(number: "03", text: "Stays out of your way")
        }
        .fixedSize(horizontal: false, vertical: true)
        .hardBox()
    }

    private var accessibilityContent: some View {
        StepCard {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("Floe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Spacer()
                InkSwitch(isOn: model.justGranted)
            }

            Rectangle().fill(Palette.rule).frame(height: Palette.line).padding(.vertical, 12)

            HStack(spacing: 8) {
                if model.waitingForAccess {
                    ProgressView().controlSize(.small)
                }
                Text(accessHint)
                    .font(.label(11))
                    .foregroundStyle(Palette.inkSoft)
            }
        }
    }

    private var accessHint: String {
        if model.justGranted { return "ACCESS GRANTED" }
        if model.waitingForAccess { return "WAITING FOR YOU TO SWITCH IT ON…" }
        return "SYSTEM SETTINGS › PRIVACY & SECURITY › ACCESSIBILITY"
    }

    private var checksContent: some View {
        VStack(spacing: 14) {
            ForEach(model.issues) { issue in
                StepCard {
                    HStack(alignment: .top, spacing: 12) {
                        Text("!")
                            .font(.label(14, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Palette.ink)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(issue.title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text(issue.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.inkSoft)
                                .fixedSize(horizontal: false, vertical: true)
                            if issue.settingsURL != nil {
                                Button("Open Settings") { model.openSettings(for: issue) }
                                    .buttonStyle(LinkButtonStyle())
                                    .padding(.top, 2)
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var desktopsContent: some View {
        switch model.desktopSetup {
        case .offer:
            StepCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(desktopLayoutsText)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Rectangle().fill(Palette.rule).frame(height: Palette.line)
                    Toggle("Keep desktop layouts on after this", isOn: $model.keepDesktopLayouts)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .toggleStyle(InkToggleStyle())
                    Text("YOU CAN CHANGE THIS ANY TIME IN SETTINGS › DESKTOPS.")
                        .font(.label(10))
                        .foregroundStyle(Palette.inkSoft)
                }
            }
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("ADDING DESKTOPS…")
                    .font(.label(11))
                    .foregroundStyle(Palette.inkSoft)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
        case .failed:
            EmptyView()
        }
    }

    private var desktopLayoutsText: String {
        let count = model.layoutDesktopCount.map { "\($0) desktops" } ?? "desktops"
        return "This turns on desktop layouts: Floe gives your Mac \(count) and keeps them. When monitors come and go, every window goes back to its desktop number."
    }

    private var practiceContent: some View {
        let keys = model.practice == .goThere ? model.practiceKeys?.there : model.practiceKeys?.back
        return HStack(spacing: 14) {
            ForEach(Array(Self.caps(keys ?? "").enumerated()), id: \.offset) { _, cap in
                Keycap(label: cap)
                    .scaleEffect(1.5)
                    .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 22)
        .opacity(model.practice == .finished ? 0.25 : 1)
    }

    @ViewBuilder
    private var appsContent: some View {
        switch model.appSwitch {
        case .offer:
            StepCard {
                VStack(alignment: .leading, spacing: 12) {
                    CheatRow(caps: ["fn", model.finderKey], text: "Jump to Finder")
                    CheatRow(caps: ["fn", "⇧", model.finderKey], text: "Bring a Finder window to this desktop")
                    Rectangle().fill(Palette.rule).frame(height: Palette.line)
                    Text("FLOE SETS “PRESS 🌐 KEY TO” TO DO NOTHING, SO FN DOESN'T ALSO OPEN THE EMOJI PICKER.")
                        .font(.label(10))
                        .foregroundStyle(Palette.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .jump, .pull, .finished:
            HStack(spacing: 14) {
                ForEach(Array(appCaps.enumerated()), id: \.offset) { _, cap in
                    Keycap(label: cap)
                        .scaleEffect(1.5)
                        .padding(.horizontal, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 22)
            .opacity(model.appSwitch == .finished ? 0.25 : 1)
        }
    }

    private var appCaps: [String] {
        model.appSwitch == .jump ? ["fn", model.finderKey] : ["fn", "⇧", model.finderKey]
    }

    private var doneContent: some View {
        StepCard {
            VStack(alignment: .leading, spacing: 9) {
                if model.hasDesktops, let focus = model.desktopModifiers.focus {
                    CheatRow(caps: Self.caps(focus) + ["1–9"], text: "Switch desktops")
                }
                if model.hasDesktops, let send = model.desktopModifiers.send {
                    CheatRow(caps: Self.caps(send) + ["1–9"], text: "Send the window to a desktop")
                }
                if model.appSwitcherOn {
                    CheatRow(caps: ["fn", "A–Z"], text: "Jump to an app, add ⇧ to bring it here")
                }
                CheatRow(caps: ["⌃", "drag"], text: "Resize tiled windows")
                CheatRow(caps: ["drop"], text: "Drop a window on another to swap them")
                Rectangle().fill(Palette.rule).frame(height: Palette.line)
                HStack(spacing: 5) {
                    Keycap(symbol: MenuBarIcon.symbol)
                    Text("Settings: click this icon in the menu bar, at the top of your screen")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 8)
                }
                Toggle("Open Floe when you log in", isOn: Binding(
                    get: { model.opensAtLogin },
                    set: { model.setOpensAtLogin($0) }
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .toggleStyle(InkToggleStyle())
            }
        }
    }

    // MARK: - Buttons

    @ViewBuilder
    private var buttons: some View {
        switch model.step {
        case .welcome:
            Button("Let's go") { model.next() }
                .buttonStyle(InkButtonStyle())
                .keyboardShortcut(.defaultAction)
        case .accessibility:
            if model.justGranted {
                Button("Continue") { model.next() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(model.waitingForAccess ? "Open System Settings again" : "Open System Settings") {
                    model.requestAccess()
                }
                .buttonStyle(InkButtonStyle(inverted: model.waitingForAccess))
                .keyboardShortcut(.defaultAction)
            }
        case .checks:
            Button(model.issues.isEmpty ? "Continue" : "Skip for now") { model.next() }
                .buttonStyle(InkButtonStyle(inverted: !model.issues.isEmpty))
                .keyboardShortcut(.defaultAction)
        case .desktops:
            switch model.desktopSetup {
            case .offer:
                VStack(spacing: 10) {
                    Button("Set up desktops") { model.setUpDesktops() }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    HStack {
                        Spacer()
                        Button("Not now") { model.skipDesktops() }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            case .working:
                EmptyView()
            case .failed:
                Button("Continue") { model.skipDesktops() }
                    .buttonStyle(InkButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        case .practice:
            HStack {
                Spacer()
                Button("Skip") { model.next() }
                    .buttonStyle(LinkButtonStyle())
            }
        case .apps:
            if model.appSwitch == .offer {
                VStack(spacing: 10) {
                    Button("Turn on the app switcher") { model.enableAppSwitcher() }
                        .buttonStyle(InkButtonStyle())
                        .keyboardShortcut(.defaultAction)
                    HStack {
                        Spacer()
                        Button("Not now") { model.next() }
                            .buttonStyle(LinkButtonStyle())
                    }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Skip") { model.next() }
                        .buttonStyle(LinkButtonStyle())
                }
            }
        case .done:
            Button("Start tiling") {
                model.finish()
                dismissWindow(id: "onboarding")
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
    }

    /// "⌃⇧2" → ["⌃", "⇧", "2"], "fn ⌃1" → ["fn", "⌃", "1"].
    static func caps(_ shortcut: String) -> [String] {
        var rest = Substring(shortcut)
        var caps: [String] = []
        if rest.hasPrefix("fn ") {
            caps.append("fn")
            rest = rest.dropFirst(3)
        }
        while let first = rest.first, "⌃⌥⇧⌘".contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }
}

// MARK: - Pieces

private struct FeatureCell: View {
    let number: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(number)
                .font(.label(11, weight: .bold))
                .foregroundStyle(Palette.inkSoft)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(14)
    }
}

/// A real toggle drawn as an `InkSwitch`.
private struct InkToggleStyle: ToggleStyle {
    func makeBody(configuration: ToggleStyleConfiguration) -> some View {
        HStack {
            configuration.label
            Spacer()
            InkSwitch(isOn: configuration.isOn)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

private struct CheatRow: View {
    let caps: [String]
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(caps, id: \.self) { Keycap(label: $0) }
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.ink)
                .padding(.leading, 8)
        }
    }
}

/// Lets the welcome follow the user to other desktops and be dragged by
/// its background, since it has no title bar.
private struct WindowConfigurator: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context: Context) -> NSView {
        let view = ActivateOnHoverView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.collectionBehavior.insert(.canJoinAllSpaces)
            window.isMovableByWindowBackground = true
            window.level = floating ? .floating : .normal
            window.center()
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let floating = floating
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let level: NSWindow.Level = floating ? .floating : .normal
            guard window.level != level else { return }
            window.level = level
            if floating {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

/// Brings the welcome forward as soon as the pointer is over it. With focus
/// follows mouse another app is usually active, and macOS would swallow the
/// first click and keep showing that app's cursor.
private final class ActivateOnHoverView: NSView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { activate() }

    /// Another app can take focus while the pointer stays put, such as
    /// after switching desktops, so moving the pointer counts too.
    override func mouseMoved(with event: NSEvent) { activate() }

    private func activate() {
        guard let window, !(NSApp.isActive && window.isKeyWindow) else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}
