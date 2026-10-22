import SwiftUI

/// Black ink on white paper, sharp edges and hard shadows.
enum Palette {
    static let paper = Color(white: 0.985)
    static let ink = Color(white: 0.04)
    static let inkSoft = Color(white: 0.38)
    static let rule = Color(white: 0.04)
    static let line: CGFloat = 1.5
    static let shadow: CGFloat = 5
}

extension Font {
    /// Small caps-style labels: buttons, step numbers, captions.
    static func label(_ size: CGFloat = 12, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// A box with a black outline and a hard shadow offset to the bottom right.
struct HardBox: ViewModifier {
    var fill: Color = .white
    var shadow: CGFloat = Palette.shadow

    func body(content: Content) -> some View {
        content
            .background(fill)
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Palette.line))
            .background(Rectangle().fill(Palette.ink).offset(x: shadow, y: shadow))
    }
}

extension View {
    func hardBox(fill: Color = .white, shadow: CGFloat = Palette.shadow) -> some View {
        modifier(HardBox(fill: fill, shadow: shadow))
    }
}

/// The main button: solid black. It lifts off its shadow under the
/// pointer and drops onto it when pressed.
struct InkButtonStyle: ButtonStyle {
    var inverted = false

    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        InkButton(configuration: configuration, inverted: inverted)
    }

    private struct InkButton: View {
        let configuration: ButtonStyleConfiguration
        let inverted: Bool
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            let lift: CGFloat = pressed ? -Palette.shadow : (hovering ? 2 : 0)
            HStack(spacing: 10) {
                configuration.label
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
                    .offset(x: hovering && !pressed ? 4 : 0)
            }
            .font(.label(13, weight: .bold))
            .textCase(.uppercase)
            .kerning(1.2)
            .foregroundStyle(inverted ? Palette.ink : .white)
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .background(inverted ? .white : Palette.ink)
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Palette.line))
            .offset(x: -lift, y: -lift)
            .background(
                Rectangle()
                    .strokeBorder(Palette.rule, lineWidth: Palette.line)
                    .background(.white)
                    .offset(x: Palette.shadow, y: Palette.shadow)
            )
            .animation(.easeOut(duration: 0.1), value: pressed)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .pointerStyle(.link)
        }
    }
}

/// An underlined text button for "skip" and "open settings".
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        configuration.label
            .font(.label(11, weight: .bold))
            .textCase(.uppercase)
            .kerning(1)
            .underline()
            .foregroundStyle(Palette.ink.opacity(configuration.isPressed ? 0.4 : 1))
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .pointerStyle(.link)
    }
}

/// What the bear says: a box whose square notch points up at the bear.
struct SpeechBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.system(size: 21, weight: .regular, design: .serif))
            .foregroundStyle(Palette.ink)
            .lineSpacing(3)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .hardBox()
            .overlay(alignment: .top) {
                ZStack {
                    Notch(cover: Palette.line).fill(.white)
                    Notch().stroke(Palette.rule, lineWidth: Palette.line)
                }
                .frame(width: 16, height: 12)
                .offset(y: -12 + Palette.line)
            }
    }
}

/// The notch's left edge and slope. With `cover`, it also reaches below its
/// base to paint over the box's top line.
private struct Notch: Shape {
    var cover: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY + cover))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        if cover > 0 {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY + cover))
            path.closeSubpath()
        }
        return path
    }
}

/// One square per step, filled as the user moves on.
struct StepMeter: View {
    let index: Int
    let count: Int

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(i <= index ? Palette.ink : .clear)
                        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Palette.line))
                        .frame(height: 8)
                }
            }
            Text(String(format: "%02d/%02d", index + 1, count))
                .font(.label(11, weight: .bold))
                .foregroundStyle(Palette.ink)
                .monospacedDigit()
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }
}

/// A key on a keyboard, for showing shortcuts. With a symbol, it shows an
/// icon instead, like the menu bar icon.
struct Keycap: View {
    var label = ""
    var symbol: String?

    init(label: String) { self.label = label }
    init(symbol: String) { self.symbol = symbol }

    var body: some View {
        face
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 9)
            .frame(minWidth: 30, minHeight: 30)
            .hardBox(shadow: 3)
            .padding(.trailing, 3)
            .padding(.bottom, 3)
    }

    @ViewBuilder
    private var face: some View {
        if let symbol {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold))
        } else {
            Text(label).font(.label(14, weight: .bold))
        }
    }
}

/// White box for the content of a step.
struct StepCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hardBox()
    }
}

/// A square switch like the toggle in System Settings, drawn in ink.
struct InkSwitch: View {
    let isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Rectangle().fill(isOn ? Palette.ink : .white)
            Rectangle()
                .fill(isOn ? .white : Palette.ink)
                .frame(width: 14, height: 14)
                .padding(3)
        }
        .frame(width: 42, height: 20)
        .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: Palette.line))
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}

// MARK: - Confetti

/// A burst of black and grey paper squares, fired again whenever `trigger` changes.
struct Confetti: View {
    let trigger: Int

    @State private var start: Date?
    private static let shades: [Color] = [Palette.ink, Palette.ink, Color(white: 0.55), Color(white: 0.8)]
    private static let pieces: [(angle: Double, speed: Double, spin: Double, shade: Int, size: Double)] =
        (0..<60).map { i in
            var rng = SeededRandom(seed: UInt64(i + 1))
            return (Double.random(in: -0.95 ... -0.05, using: &rng) * .pi,
                    Double.random(in: 240...500, using: &rng),
                    Double.random(in: -7...7, using: &rng),
                    Int.random(in: 0..<4, using: &rng),
                    Double.random(in: 5...10, using: &rng))
        }

    var body: some View {
        TimelineView(.animation(paused: start == nil)) { timeline in
            Canvas { context, size in
                guard let start else { return }
                let t = timeline.date.timeIntervalSince(start)
                guard t < 2.6 else { return }
                let origin = CGPoint(x: size.width / 2, y: size.height * 0.3)
                for piece in Self.pieces {
                    let x = origin.x + cos(piece.angle) * piece.speed * t
                    let y = origin.y + sin(piece.angle) * piece.speed * t + 420 * t * t
                    var ctx = context
                    ctx.opacity = max(0, 1 - t / 2.6)
                    ctx.translateBy(x: x, y: y)
                    ctx.rotate(by: .radians(piece.spin * t))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 2, width: piece.size, height: piece.size)
                    ctx.fill(Path(rect), with: .color(Self.shades[piece.shade]))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            let burst = Date()
            start = burst
            // Stop the timeline once the pieces have fallen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.7) {
                if start == burst { start = nil }
            }
        }
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
