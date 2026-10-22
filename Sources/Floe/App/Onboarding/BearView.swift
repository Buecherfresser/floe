import AVFoundation
import SwiftUI

/// The bear's animations. Each is a video in the app's `Resources/Bear`
/// folder, named after the case (`wave.mov`, …).
enum BearClip: String {
    case wave, idle, point, wait, cheer, oops

    /// One-shot clips play once and hand over to `idle`.
    var loops: Bool {
        switch self {
        case .wave, .cheer: false
        case .idle, .point, .wait, .oops: true
        }
    }

    var url: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "mov", subdirectory: "Bear")
    }
}

/// Plays the bear's clips, or a bouncing stand-in bear while the videos
/// aren't in the app.
struct BearView: View {
    let clip: BearClip

    var body: some View {
        if clip.url != nil || BearClip.idle.url != nil {
            BearVideo(clip: clip)
        } else {
            StandInBear(clip: clip)
        }
    }
}

// MARK: - Video

private struct BearVideo: NSViewRepresentable {
    let clip: BearClip

    func makeNSView(context: Context) -> BearPlayerView { BearPlayerView() }

    func updateNSView(_ view: BearPlayerView, context: Context) {
        view.play(clip)
    }
}

/// Plays one clip at a time and crossfades between them, so a jump from
/// one pose to the next doesn't show.
final class BearPlayerView: NSView {
    private struct Track {
        let player: AVQueuePlayer
        let layer: AVPlayerLayer
        let looper: AVPlayerLooper?
        let endObserver: NSObjectProtocol?
    }

    private var track: Track?
    /// The clip SwiftUI asked for. A one-shot hands over to `idle` on its own.
    private var requested: BearClip?
    private var playingURL: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        track?.layer.frame = bounds
    }

    func play(_ clip: BearClip) {
        guard clip != requested else { return }
        requested = clip
        start(clip)
    }

    private func start(_ clip: BearClip) {
        // A missing clip falls back to idle, which may already be playing.
        let resolved = clip.url != nil ? clip : .idle
        guard let url = resolved.url, url != playingURL || !resolved.loops else { return }
        playingURL = url

        let player = AVQueuePlayer()
        player.isMuted = true
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = bounds
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .clear
        // Keeps the alpha channel of HEVC-with-alpha clips.
        playerLayer.pixelBufferAttributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        playerLayer.opacity = 0
        layer?.addSublayer(playerLayer)

        let item = AVPlayerItem(url: url)
        var looper: AVPlayerLooper?
        var endObserver: NSObjectProtocol?
        if resolved.loops {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.start(.idle) }
            }
        }
        player.play()

        let old = track
        track = Track(player: player, layer: playerLayer, looper: looper, endObserver: endObserver)
        fade(playerLayer, to: 1)
        if let old {
            fade(old.layer, to: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                old.player.pause()
                old.layer.removeFromSuperlayer()
                if let observer = old.endObserver { NotificationCenter.default.removeObserver(observer) }
            }
        }
    }

    private func fade(_ layer: CALayer, to opacity: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = layer.presentation()?.opacity ?? layer.opacity
        animation.toValue = opacity
        animation.duration = 0.25
        layer.opacity = opacity
        layer.add(animation, forKey: "fade")
    }
}

// MARK: - Stand-in

/// The app icon's bear, animated with SwiftUI so every step has some life
/// before the real clips exist.
private struct StandInBear: View {
    let clip: BearClip
    @State private var phase = false
    @State private var hop = false

    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .scaledToFit()
            .rotationEffect(.degrees(rotation), anchor: .bottom)
            .scaleEffect(scale, anchor: .bottom)
            .offset(y: hop ? -26 : (phase ? bob : 0))
            .onAppear(perform: animate)
            .onChange(of: clip) { animate() }
    }

    private var rotation: Double {
        switch clip {
        case .wave: phase ? 9 : -9
        case .oops: phase ? 3 : -3
        default: 0
        }
    }

    private var scale: CGFloat {
        switch clip {
        case .idle, .point: phase ? 1.02 : 0.98
        default: 1
        }
    }

    private var bob: CGFloat {
        switch clip {
        case .wait: -6
        case .point: -3
        default: 0
        }
    }

    private func animate() {
        phase = false
        hop = false
        let speed: Double = switch clip {
        case .wave: 0.22
        case .oops: 0.12
        case .wait: 0.9
        default: 1.4
        }
        withAnimation(.easeInOut(duration: speed).repeatForever(autoreverses: true)) {
            phase = true
        }
        if clip == .cheer {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.45).repeatCount(3, autoreverses: true)) {
                hop = true
            }
        }
    }
}
