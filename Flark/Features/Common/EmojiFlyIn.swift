import SwiftUI
import FlarkKit

/// One in-flight emoji animation. `target` is the rect the emoji will land
/// on, in the shared named coordinate space (see `TopicDetailView`'s
/// `topicDetailRoot` space).
///
/// Reference type with `@Observable` `target` so source views can push
/// updated frames into a live flight (e.g. when the user scrolls during
/// the animation) and the `FlightView` reading `flight.target` re-renders
/// + smoothly redirects to the new landing spot.
@Observable
final class EmojiFlight: Identifiable {
    let id = UUID()
    let emojiID: String
    var target: CGRect

    init(emojiID: String, target: CGRect) {
        self.emojiID = emojiID
        self.target = target
    }
}

/// Per-detail-page list of currently-animating flights. Lives as `@State` on
/// `TopicDetailView` and is exposed to descendants via `.environment(...)`
/// so sources (reaction chips, inline text glyphs) can request a flight and
/// the overlay layer can render them.
@Observable
final class EmojiFlightHost {
    /// The single flight currently animating. The overlay renders only
    /// this one — there's never more than one in flight at a time since
    /// the easter-egg button picks one emoji per press.
    var activeFlight: EmojiFlight? = nil

    /// Source emojis currently on-screen, keyed by id. Source modifiers
    /// call `register(...)` on appear / frame change and `unregister(...)`
    /// on disappear; `flyRandom()` picks one at random from this set.
    @ObservationIgnored
    private var visibleSources: [String: CGRect] = [:]

    /// Parallel dict of the same sources in WINDOW coordinates (i.e.
    /// `.global` SwiftUI space). The UIKit picker-arc fly-in animates
    /// in window space, so it queries this map; the SwiftUI overlay
    /// continues to use the named-space `visibleSources`.
    @ObservationIgnored
    private var visibleSourcesGlobal: [String: CGRect] = [:]

    /// Register or refresh a source emoji as currently visible. `target`
    /// is in the named coordinate space (for the SwiftUI overlay);
    /// optional `globalTarget` is in window coordinates (for the UIKit
    /// picker-arc fly-in). Also updates any in-flight target for the
    /// same id so scroll moves the landing spot under an active flight.
    func register(emojiID: String, target: CGRect,
                  globalTarget: CGRect = .zero) {
        guard target.width > 0, target.height > 0 else { return }
        visibleSources[emojiID] = target
        if globalTarget.width > 0, globalTarget.height > 0 {
            visibleSourcesGlobal[emojiID] = globalTarget
        }
        if let activeFlight, activeFlight.emojiID == emojiID {
            activeFlight.target = target
        }
    }

    /// Remove a source emoji from the visible set (scrolled off-screen,
    /// view torn down, etc.). Does NOT cancel an in-flight animation
    /// already targeting it — that completes on its current trajectory.
    func unregister(emojiID: String) {
        visibleSources.removeValue(forKey: emojiID)
        visibleSourcesGlobal.removeValue(forKey: emojiID)
    }

    /// Pick a random visible source and start a flight. No-op when
    /// nothing is visible or another flight is already animating (so the
    /// button doesn't stack flights on top of each other).
    func flyRandom() {
        guard activeFlight == nil else { return }
        guard let pick = visibleSources.randomElement() else { return }
        activeFlight = EmojiFlight(emojiID: pick.key, target: pick.value)
    }

    func finish(_ id: UUID) {
        guard activeFlight?.id == id else { return }
        activeFlight = nil
    }

    /// Latest registered frame for an emoji id (named coord space), or
    /// `nil` if no source view has registered it.
    func liveSource(for emojiID: String) -> CGRect? {
        visibleSources[emojiID]
    }

    /// Latest registered frame for an emoji id in WINDOW coordinates,
    /// or `nil` if not registered with a global frame. Used by the
    /// UIKit picker-arc fly-in (which animates in window space).
    func liveGlobalSource(for emojiID: String) -> CGRect? {
        visibleSourcesGlobal[emojiID]
    }

    /// Register a synthetic landing anchor (in window coordinates) under
    /// a non-emoji key — e.g. the reaction bar's "next chip will go
    /// here" position. Lives only in the global-source map, so it
    /// doesn't get picked up by `flyRandom()` or the SwiftUI overlay.
    func registerAnchor(id: String, globalFrame: CGRect) {
        guard globalFrame.width > 0, globalFrame.height > 0 else { return }
        visibleSourcesGlobal[id] = globalFrame
    }

    /// Inverse of `registerAnchor(id:globalFrame:)`.
    func unregisterAnchor(id: String) {
        visibleSourcesGlobal.removeValue(forKey: id)
    }

    /// Key for a reaction chip's global frame, scoped per target. The
    /// flat `emojiID` registration overwrites itself when the same
    /// emoji appears in multiple reaction bars (e.g. 🐔 on both the
    /// topic and a reply), so the reaction-picker fly-in needs this
    /// scoped key to find the chip on the specific target it's adding
    /// the reaction to — otherwise the descent lands on whichever bar
    /// re-registered last (usually the topic).
    static func chipAnchorKey(emojiID: String,
                              targetID: String,
                              targetType: TargetType) -> String {
        "chip:\(targetType):\(targetID):\(emojiID)"
    }
}

// MARK: - Optional environment key

/// `@Environment(EmojiFlightHost.self)` crashes when no host is provided
/// — fine for views inside `TopicDetailView` which always injects one,
/// but the reaction picker also runs from the topic list (no host
/// there). This optional-typed key returns `nil` when no host is in
/// scope, letting callers gate the fly-in feature.
private struct OptionalEmojiFlightHostKey: EnvironmentKey {
    static let defaultValue: EmojiFlightHost? = nil
}

extension EnvironmentValues {
    var optionalEmojiFlightHost: EmojiFlightHost? {
        get { self[OptionalEmojiFlightHostKey.self] }
        set { self[OptionalEmojiFlightHostKey.self] = newValue }
    }
}

/// Tuning constants for the fly-in animation. Pulled out so all callsites
/// agree and the visual can be retuned in one place.
enum EmojiFlyInConstants {
    /// Scale factor applied to the target size at the start of the flight.
    /// 5× of a ~22pt inline emoji puts the entering glyph at ~110pt, which
    /// reads as "really big" without dominating the screen on small devices.
    static let startScale: CGFloat = 5.0

    /// Opacity while the giant emoji is floating across the screen.
    /// Just slightly transparent so the underlying content is hinted at
    /// behind the giant glyph but the emoji itself reads as essentially
    /// solid.
    static let floatingOpacity: Double = 0.95

    /// home → left edge. Scale grows from 1.0 → `startScale` and opacity
    /// fades to `floatingOpacity` during this phase, so the emoji
    /// "blossoms" out of its home position rather than popping in.
    static let phaseHomeToLeftSeconds: Double = 0.90

    /// left edge → right edge (the long mid-sweep at full size).
    static let phaseLeftToRightSeconds: Double = 1.30

    /// right edge → home, with scale shrinking back to 1.0 and opacity
    /// rising back to 1.0 so the landing reads as the giant glyph
    /// collapsing back into the original emoji.
    static let phaseRightToHomeSeconds: Double = 0.90

    /// Spring used to chase live target updates when the user scrolls
    /// mid-flight. Slow enough to look intentional, fast enough to keep
    /// up with reasonable scroll velocities.
    static let chaseAnimation: Animation =
        .spring(response: 0.50, dampingFraction: 0.85)
}

/// Animatable container for the keyframe-driven flight path. `dx`/`dy` are
/// offsets from the target rect's centre; `scale` is the visual scale on
/// top of the natural emoji size; `opacity` is the rendering alpha.
private struct FlightPose {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var scale: CGFloat = 1
    var opacity: Double = 1
}

/// Topmost layer of `TopicDetailView` — renders every in-flight emoji as an
/// absolutely-positioned overlay. Sits inside the same named coordinate
/// space the source frames were captured in, so positions line up exactly.
struct EmojiFlightOverlay: View {
    let host: EmojiFlightHost
    @Environment(AppModel.self) private var model

    var body: some View {
        // GeometryReader so FlightView knows the visible right-edge.
        // We render at most one flight (`host.activeFlight`) so emojis
        // queue and play sequentially instead of stacking. `.id(flight.id)`
        // forces a fresh view on each flight so `.task` re-runs from
        // initial pose.
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let flight = host.activeFlight {
                    FlightView(flight: flight,
                               screenWidth: proxy.size.width,
                               item: model.emoji.item(flight.emojiID)) {
                        host.finish(flight.id)
                    }
                    .id(flight.id)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// One animating emoji. Pops into existence at its own home position
    /// at `startScale`, sweeps to the left edge of the screen, across to
    /// the right edge, then springs back home and shrinks to scale 1.0.
    /// All edges matched with easeInOut so the motion reads as one
    /// continuous bounce-curve.
    private struct FlightView: View {
        let flight: EmojiFlight
        let screenWidth: CGFloat
        let item: EmojiItem?
        let onFinish: () -> Void

        @State private var pose: FlightPose = .init()
        @State private var didStart: Bool = false

        var body: some View {
            // Reading flight.target.midX/midY here registers an
            // Observation dependency, so when the source view pushes a
            // new frame (scroll while in flight), the body re-renders
            // and the `.animation(value:)` modifier smoothly re-routes
            // the giant emoji to the new home spot.
            let tx = flight.target.midX
            let ty = flight.target.midY
            EmojiGlyph(item: item, size: flight.target.height)
                .scaleEffect(pose.scale, anchor: .center)
                .opacity(pose.opacity)
                .position(x: tx + pose.dx, y: ty + pose.dy)
                .animation(EmojiFlyInConstants.chaseAnimation, value: tx)
                .animation(EmojiFlyInConstants.chaseAnimation, value: ty)
                .task { await runFlight() }
        }

        private func runFlight() async {
            guard !didStart else { return }
            didStart = true

            let size = flight.target.height
            let startScale = EmojiFlyInConstants.startScale
            let visualHalfWidth = size * startScale / 2
            let floatOpacity = EmojiFlyInConstants.floatingOpacity
            // Left edge: emoji's left edge just touches the screen's left
            // edge (centre = visual half-width).
            let leftX = visualHalfWidth - flight.target.midX
            // Right edge: emoji's right edge just touches the screen's
            // right edge (centre = screenWidth - visual half-width).
            let rightX = screenWidth - visualHalfWidth - flight.target.midX

            // Initial pose — sit exactly on top of the home emoji, same
            // size, fully opaque. Visually indistinguishable until Phase 1
            // starts to grow + move us off, so the flight reads as the
            // original emoji "blossoming" outward.
            pose = FlightPose(dx: 0, dy: 0, scale: 1.0, opacity: 1.0)
            try? await Task.sleep(for: .milliseconds(16))

            // Phase 1 — home → left edge, growing from 1× to `startScale`
            // and fading to `floatingOpacity`. easeOut so most of the
            // growth happens early (the user sees the "explosion" upfront).
            let p1 = EmojiFlyInConstants.phaseHomeToLeftSeconds
            withAnimation(.easeOut(duration: p1)) {
                pose.dx = leftX
                pose.scale = startScale
                pose.opacity = floatOpacity
            }
            try? await Task.sleep(for: .milliseconds(Int(p1 * 1000)))

            // Phase 2 — left edge → right edge (the long mid-sweep at
            // full size, semi-transparent).
            let p2 = EmojiFlyInConstants.phaseLeftToRightSeconds
            withAnimation(.easeInOut(duration: p2)) {
                pose.dx = rightX
            }
            try? await Task.sleep(for: .milliseconds(Int(p2 * 1000)))

            // Phase 3 — right edge → home, shrink back to 1.0, fully
            // opaque so the landing collapses the giant glyph back into
            // the original emoji. easeIn so the shrink accelerates into
            // the home position.
            let p3 = EmojiFlyInConstants.phaseRightToHomeSeconds
            withAnimation(.easeIn(duration: p3)) {
                pose.dx = 0
                pose.scale = 1.0
                pose.opacity = 1.0
            }
            try? await Task.sleep(for: .milliseconds(Int(p3 * 1000)))
            onFinish()
        }
    }
}

// MARK: - Source-side modifier (SwiftUI EmojiGlyph instances)

private struct EmojiFlyInSourceModifier: ViewModifier {
    let emojiID: String
    let space: String

    @Environment(EmojiFlightHost.self) private var host

    @State private var lastFrame: CGRect = .zero
    @State private var lastGlobalFrame: CGRect = .zero
    @State private var visible: Bool = false

    func body(content: Content) -> some View {
        // iOS 18+ : true scroll visibility. iOS 17 fallback: onAppear
        // (treat as visible) / onDisappear (treat as gone).
        if #available(iOS 18.0, *) {
            content
                .background { frameReader() }
                .onScrollVisibilityChange(threshold: 0.5) { v in
                    visible = v
                    sync()
                }
                .onDisappear { host.unregister(emojiID: emojiID) }
        } else {
            content
                .background { frameReader() }
                .onAppear {
                    visible = true
                    sync()
                }
                .onDisappear {
                    visible = false
                    host.unregister(emojiID: emojiID)
                }
        }
    }

    private func frameReader() -> some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear {
                    lastFrame = proxy.frame(in: .named(space))
                    lastGlobalFrame = proxy.frame(in: .global)
                    sync()
                }
                .onChange(of: proxy.frame(in: .named(space))) { _, new in
                    lastFrame = new
                    sync()
                }
                .onChange(of: proxy.frame(in: .global)) { _, new in
                    lastGlobalFrame = new
                    sync()
                }
        }
    }

    /// Reconcile our registration with the host: visible + measured →
    /// register (which also updates any in-flight target for scroll-
    /// follow); not visible → unregister.
    private func sync() {
        if visible, lastFrame.width > 0 {
            host.register(emojiID: emojiID,
                          target: lastFrame,
                          globalTarget: lastGlobalFrame)
        } else {
            host.unregister(emojiID: emojiID)
        }
    }
}

extension View {
    /// Attach to a SwiftUI emoji view (e.g. `EmojiGlyph` in the reaction
    /// bar). When the view first becomes visible inside the enclosing
    /// scroll view, requests a fly-in flight on the ambient
    /// `EmojiFlightHost` — but only if this emoji id hasn't already been
    /// animated this launch (per `EmojiFlyInTracker`).
    ///
    /// `space` must match the named coordinate space attached to the root
    /// of the detail page (`topicDetailRoot`).
    func emojiFlyInSource(id: String, space: String) -> some View {
        modifier(EmojiFlyInSourceModifier(emojiID: id, space: space))
    }

    /// Per-target scoped registration for a reaction chip's window
    /// frame. Layered on top of `.emojiFlyInSource` (which only stores
    /// frames keyed by emojiID globally), so the reaction-picker arc
    /// fly-in can address the specific chip on a specific target —
    /// not "whichever bar happened to register this emoji last".
    func emojiFlyInChipAnchor(emojiID: String,
                              targetID: String,
                              targetType: TargetType) -> some View {
        modifier(ChipAnchorModifier(emojiID: emojiID,
                                    targetID: targetID,
                                    targetType: targetType))
    }
}

private struct ChipAnchorModifier: ViewModifier {
    let emojiID: String
    let targetID: String
    let targetType: TargetType
    @Environment(\.optionalEmojiFlightHost) private var host

    func body(content: Content) -> some View {
        content.background {
            if let host {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { register(host: host, proxy: proxy) }
                        .onChange(of: proxy.frame(in: .global)) { _, _ in
                            register(host: host, proxy: proxy)
                        }
                        .onDisappear {
                            host.unregisterAnchor(id: key)
                        }
                }
            }
        }
    }

    private var key: String {
        EmojiFlightHost.chipAnchorKey(emojiID: emojiID,
                                      targetID: targetID,
                                      targetType: targetType)
    }

    private func register(host: EmojiFlightHost, proxy: GeometryProxy) {
        host.registerAnchor(id: key,
                            globalFrame: proxy.frame(in: .global))
    }
}

// MARK: - Inline-text wrapper (NSTextAttachment glyphs inside AttrInlineText)

#if canImport(UIKit)
/// Per-glyph layout reported up out of `AttrInlineText` so the SwiftUI
/// caller can spawn fly-in flights for each emoji attachment. Frame is in
/// the UITextView's own coordinate space; the caller is responsible for
/// translating to the shared named coordinate space.
struct InlineEmojiLayout {
    let id: String
    let frameInTextView: CGRect
}

/// Drop-in replacement for `AttrInlineText` used on the detail page —
/// registers each inline emoji attachment as a visible candidate with the
/// ambient `EmojiFlightHost` so the easter-egg button can randomly pick
/// one to fly. List-page rows use plain `AttrInlineText` and don't
/// participate in fly-ins.
struct InlineTextWithFlyIn: View {
    let attributed: NSAttributedString
    var maxLines: Int = 0
    let space: String

    @Environment(EmojiFlightHost.self) private var host

    @State private var textViewOrigin: CGPoint = .zero
    @State private var textViewGlobalOrigin: CGPoint = .zero
    @State private var latestLayouts: [InlineEmojiLayout] = []
    @State private var visible: Bool = false

    var body: some View {
        if #available(iOS 18.0, *) {
            base
                .onScrollVisibilityChange(threshold: 0.5) { v in
                    visible = v
                    sync()
                }
                .onDisappear { unregisterAll() }
        } else {
            base
                .onAppear {
                    visible = true
                    sync()
                }
                .onDisappear {
                    visible = false
                    unregisterAll()
                }
        }
    }

    private var base: some View {
        AttrInlineText(attributed: attributed, maxLines: maxLines,
                       onEmojiLayouts: { layouts in
            latestLayouts = layouts
            sync()
        })
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        textViewOrigin = proxy.frame(in: .named(space)).origin
                        textViewGlobalOrigin = proxy.frame(in: .global).origin
                        sync()
                    }
                    .onChange(of: proxy.frame(in: .named(space))) { _, new in
                        textViewOrigin = new.origin
                        sync()
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, new in
                        textViewGlobalOrigin = new.origin
                        sync()
                    }
            }
        }
    }

    /// Reconcile our per-emoji registrations with the host.
    private func sync() {
        guard visible else { unregisterAll(); return }
        for layout in latestLayouts {
            let named = CGRect(
                x: layout.frameInTextView.minX + textViewOrigin.x,
                y: layout.frameInTextView.minY + textViewOrigin.y,
                width: layout.frameInTextView.width,
                height: layout.frameInTextView.height)
            let global = CGRect(
                x: layout.frameInTextView.minX + textViewGlobalOrigin.x,
                y: layout.frameInTextView.minY + textViewGlobalOrigin.y,
                width: layout.frameInTextView.width,
                height: layout.frameInTextView.height)
            host.register(emojiID: layout.id,
                          target: named, globalTarget: global)
        }
    }

    private func unregisterAll() {
        for layout in latestLayouts {
            host.unregister(emojiID: layout.id)
        }
    }
}

// MARK: - Picker → editor arc fly-in (UIKit, window-level)

/// Holds a weak reference to the composer's `UITextView` so the picker
/// callback can compute the on-screen caret rect after insertion. SwiftUI
/// doesn't otherwise hand out the underlying UIView; this `@Observable`
/// class is shared between `RichTextEditor` (which sets it on
/// `makeUIView`) and `ComposerView` (which reads it from the picker
/// dismissal handler).
@Observable
final class EditorHandle {
    weak var textView: UITextView?
}

/// Window-level UIKit overlay that animates an emoji along an arc from
/// the picker tap position to the editor's caret. Used at the moment the
/// user selects an emoji from `EmojiPickerView`: the picker sheet is
/// dismissing, the composer is still on top, and a single overlay glyph
/// rides across both via the key window.
///
/// Implemented with `CADisplayLink` (not `UIView.animateKeyframes`) so
/// the trajectory's landing point can be updated mid-flight via
/// `updateTarget(_:)` — the composer pushes a new caret rect whenever
/// the cursor moves during the animation and the descending phase
/// re-aims at the new spot.
@MainActor
final class EmojiPickerFlight: NSObject {
    /// Total duration of the arc flight. Matches the easter-egg's
    /// home→left + left→right + right→home total so both animations
    /// share the same "tempo".
    static let durationSeconds: Double =
        EmojiFlyInConstants.phaseHomeToLeftSeconds
        + EmojiFlyInConstants.phaseLeftToRightSeconds
        + EmojiFlyInConstants.phaseRightToHomeSeconds

    /// Peak visual width (in points) at the apex of the arc. Picked to
    /// match the easter-egg's big-emoji feel: `startScale × inline-emoji
    /// line height ≈ 5 × ~22pt ≈ 110pt`.
    static let peakVisualSize: CGFloat = {
        let inlineSize = UIFont.preferredFont(forTextStyle: .body)
            .lineHeight * 1.44
        return inlineSize * EmojiFlyInConstants.startScale
    }()

    /// Start a new arc flight. Returns the live flight handle, or `nil`
    /// (and immediately fires `onLanded`) if the emoji image can't be
    /// loaded. Keep the returned handle and call `updateTarget(_:)` on
    /// it whenever the destination position changes during the flight
    /// so the descending phase re-aims smoothly.
    @discardableResult
    static func fly(item: EmojiItem,
                    fromCenter: CGPoint,
                    toCenter: CGPoint,
                    pickerGlyphSize: CGFloat,
                    landingGlyphSize: CGFloat,
                    in window: UIWindow,
                    onLanded: @escaping () -> Void = {}) -> EmojiPickerFlight? {
        let resolved = EmojiPackResolver.resolvedFile(item.file)
        guard
            let url = Bundle.main.url(forResource: resolved,
                                      withExtension: nil,
                                      subdirectory: "Emoji"),
            let data = try? Data(contentsOf: url),
            let img = UIImage(data: data)
        else {
            onLanded()
            return nil
        }
        let flight = EmojiPickerFlight(image: img,
                                       from: fromCenter,
                                       to: toCenter,
                                       pickerGlyphSize: pickerGlyphSize,
                                       landingGlyphSize: landingGlyphSize,
                                       window: window,
                                       onLanded: onLanded)
        flight.start()
        return flight
    }

    /// Convenience: find the active app key window. Returns `nil` if
    /// there's none (e.g. running headless), in which case the caller
    /// should skip the fly-in.
    static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: \.isKeyWindow)
    }

    /// Update the landing target mid-flight (window coordinates). Only
    /// affects the descending phase — phases 1/2 (sweep up + hold at
    /// apex) are independent of the destination.
    func updateTarget(_ to: CGPoint) {
        guard !didLand else { return }
        target = to
    }

    /// Optional dynamic target source — queried every tick. Used by the
    /// reaction-picker fly-in where the destination chip doesn't exist
    /// at flight start; the closure polls the host until the new chip
    /// is registered, then returns its centre. Returning `nil` leaves
    /// the target unchanged.
    var targetProvider: (() -> CGPoint?)? = nil

    // MARK: - Internals

    private let glyph: UIImageView
    private weak var window: UIWindow?
    private let onLanded: () -> Void

    private let from: CGPoint
    private let apex: CGPoint
    private var target: CGPoint

    private let peakScale: CGFloat
    private let landingScale: CGFloat
    private let floatOpacity: CGFloat

    private var startTime: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var didLand = false

    private init(image: UIImage,
                 from: CGPoint, to: CGPoint,
                 pickerGlyphSize: CGFloat, landingGlyphSize: CGFloat,
                 window: UIWindow,
                 onLanded: @escaping () -> Void) {
        let v = UIImageView(image: image)
        v.contentMode = .scaleAspectFit
        v.isUserInteractionEnabled = false
        v.frame = CGRect(x: 0, y: 0,
                         width: pickerGlyphSize, height: pickerGlyphSize)
        v.center = from
        v.alpha = 1
        self.glyph = v
        self.window = window
        self.onLanded = onLanded
        self.from = from
        self.target = to
        // Apex: screen centre, guaranteed inside visible region.
        self.apex = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        self.peakScale =
            max(1.2, Self.peakVisualSize / pickerGlyphSize)
        self.landingScale =
            max(0.3, landingGlyphSize / pickerGlyphSize)
        self.floatOpacity = CGFloat(EmojiFlyInConstants.floatingOpacity)
    }

    private func start() {
        window?.addSubview(glyph)
        startTime = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func tick() {
        if let provider = targetProvider, let to = provider() {
            target = to
        }
        let elapsed = CACurrentMediaTime() - startTime
        let t = min(1, max(0, elapsed / Self.durationSeconds))
        apply(pose(at: t))
        if t >= 1, !didLand {
            didLand = true
            displayLink?.invalidate()
            displayLink = nil
            onLanded()
            glyph.removeFromSuperview()
        }
    }

    private func apply(_ pose: (center: CGPoint, scale: CGFloat, alpha: CGFloat)) {
        glyph.center = pose.center
        glyph.transform = CGAffineTransform(scaleX: pose.scale, y: pose.scale)
        glyph.alpha = pose.alpha
    }

    /// Three-phase trajectory:
    ///  - 0..0.30  : from → apex     (grow 1× → peak, fade to floatOpacity)
    ///  - 0.30..0.70: hold at apex   (constant peak + opacity)
    ///  - 0.70..1.0 : apex → target  (shrink peak → landing, opacity → 1.0)
    /// Phase 3 reads `target` live so an update mid-flight re-aims.
    private func pose(at t: Double)
        -> (center: CGPoint, scale: CGFloat, alpha: CGFloat) {
        if t < 0.30 {
            let p = Self.smoothstep(t / 0.30)
            return (Self.lerp(from, apex, p),
                    Self.lerp(1.0, peakScale, p),
                    Self.lerp(1.0, floatOpacity, p))
        } else if t < 0.70 {
            return (apex, peakScale, floatOpacity)
        } else {
            let p = Self.smoothstep((t - 0.70) / 0.30)
            return (Self.lerp(apex, target, p),
                    Self.lerp(peakScale, landingScale, p),
                    Self.lerp(floatOpacity, 1.0, p))
        }
    }

    private static func smoothstep(_ x: Double) -> Double {
        // Cubic ease-in-out, matches UIKit's calculationModeCubic feel
        // between two consecutive keyframes.
        let c = max(0, min(1, x))
        return c * c * (3 - 2 * c)
    }
    private static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let tc = CGFloat(t)
        return CGPoint(x: a.x + (b.x - a.x) * tc,
                       y: a.y + (b.y - a.y) * tc)
    }
    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }
}
#endif
