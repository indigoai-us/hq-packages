// Shared Liquid Glass look and motion for every HQ Capture surface. Surfaces are rounded: the
// control bar and buttons are capsules or circles, and panels use large continuous corners. Glass
// is see-through with a backdrop blur, and its rim carries a faint chromatic dispersion drawn as
// three slightly offset red, green and blue edge strokes blended with plusLighter. The CLT build
// has no Metal compiler, so the rim is plain SwiftUI rather than a shader.
//
// Reduce Transparency swaps glass for an opaque window background and turns the dispersion off.
// Reduce Motion swaps springs and scale changes for short crossfades. Both follow the system
// settings, and `--reduce-motion` / `--reduce-transparency` force them for screenshots.

import AppKit
import SwiftUI

enum HQMotion {
    /// The spring for state changes, or a short crossfade under Reduce Motion.
    static func smooth(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .smooth(duration: 0.38)
    }

    /// The spring for direct feedback such as presses and hover.
    static func snappy(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.12) : .snappy(duration: 0.22)
    }

    /// The spring a surface appears with: scale and opacity together.
    static func appear(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.78)
    }

    /// True when the system or the launch flag asks for Reduce Motion. For AppKit callers.
    @MainActor static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || ScreenshotStage.reduceMotion
    }

    /// True when the system or the launch flag asks for Reduce Transparency. For AppKit callers.
    @MainActor static var reduceTransparency: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || ScreenshotStage.reduceTransparency
    }
}

/// Corner radii, kept concentric: each inner radius is its container's radius minus the padding
/// between them.
enum HQRadius {
    /// The main window's glass.
    static let window: CGFloat = 26
    /// Cards inside the main window, which sit 16 points in from the window edge.
    static let card: CGFloat = 22
    /// Previews and wells inside a card, which sit 16 points in from the card edge.
    static let inset: CGFloat = 12
}

/// Reads both accessibility fallbacks from the environment and the launch flags.
struct HQAccessibility: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var systemReduceTransparency

    var reduceMotion: Bool { systemReduceMotion || ScreenshotStage.reduceMotion }
    var reduceTransparency: Bool { systemReduceTransparency || ScreenshotStage.reduceTransparency }
}

/// A rounded glass surface with a dispersion rim, or an opaque one under Reduce Transparency.
struct HQGlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var clear = false
    var interactive = false
    var tint: Color?
    private let access = HQAccessibility()
    @State private var hovering = false

    func body(content: Content) -> some View {
        if access.reduceTransparency {
            content
                .background(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Color(nsColor: .windowBackgroundColor)),
                            in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        } else {
            content
                .glassEffect(glass, in: shape)
                .overlay(HQDispersionRim(shape: shape, intensity: hovering && interactive ? 1.5 : 1))
                .onHover { hovering = $0 }
                .animation(HQMotion.snappy(access.reduceMotion), value: hovering)
        }
    }

    private var glass: Glass {
        var glass = clear ? Glass.clear : Glass.regular
        if let tint { glass = glass.tint(tint) }
        return interactive ? glass.interactive() : glass
    }
}

extension View {
    /// Rounded glass. `clear` is the more see-through variant, for surfaces that float over other
    /// apps, such as the control bar.
    func hqGlass<S: InsettableShape>(in shape: S, clear: Bool = false, interactive: Bool = false,
                                     tint: Color? = nil) -> some View {
        modifier(HQGlassSurface(shape: shape, clear: clear, interactive: interactive, tint: tint))
    }

    /// A card: rounded glass with the card radius.
    func hqGlass(clear: Bool = false, interactive: Bool = false, tint: Color? = nil) -> some View {
        hqGlass(in: .rect(cornerRadius: HQRadius.card, style: .continuous), clear: clear,
                interactive: interactive, tint: tint)
    }

    /// A system glass button: a capsule, or a circle for icon-only buttons. `prominent` marks the one
    /// primary action of the current state. The rim disperses a little more on hover and press.
    func hqGlassButton(prominent: Bool = false, circle: Bool = false) -> some View {
        modifier(HQGlassButton(prominent: prominent, circle: circle))
    }
}

/// Applies the system `.glass` or `.glassProminent` button style with the HQ rim.
struct HQGlassButton: ViewModifier {
    let prominent: Bool
    let circle: Bool
    private let access = HQAccessibility()
    @State private var hovering = false
    @State private var pressed = false

    func body(content: Content) -> some View {
        styled(content)
            .overlay {
                if circle {
                    HQDispersionRim(shape: Circle(), intensity: intensity)
                } else {
                    HQDispersionRim(shape: Capsule(), intensity: intensity)
                }
            }
            .onHover { hovering = $0 }
            .simultaneousGesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { pressed = true } }
                .onEnded { _ in pressed = false })
            .animation(HQMotion.snappy(access.reduceMotion), value: hovering)
            .animation(HQMotion.snappy(access.reduceMotion), value: pressed)
    }

    private var intensity: Double { pressed ? 2 : hovering ? 1.5 : 1 }

    @ViewBuilder
    private func styled(_ content: Content) -> some View {
        let shaped = Group {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        }
        if circle {
            shaped.buttonBorderShape(.circle)
        } else {
            shaped.buttonBorderShape(.capsule)
        }
    }
}

/// Chromatic dispersion at a glass rim: red, green and blue copies of the edge, each shifted a
/// fraction of a point, so the rim splits into color the way thick glass does at its edge. The
/// strokes are under two points wide, so they never sit behind text. Light falls from the top
/// left, so the rim is brightest there and at the opposite corner. Off under Reduce Transparency.
struct HQDispersionRim<S: InsettableShape>: View {
    let shape: S
    /// 1 at rest, higher on hover and press.
    var intensity: Double = 1
    private let access = HQAccessibility()

    var body: some View {
        if !access.reduceTransparency {
            let shift = 0.55 * intensity
            ZStack {
                channel(Color(red: 1, green: 0.22, blue: 0.32), x: -shift, y: -shift * 0.6)
                channel(Color(red: 0.25, green: 1, blue: 0.5), x: 0, y: 0)
                channel(Color(red: 0.3, green: 0.45, blue: 1), x: shift, y: shift * 0.6)
                // A thin white highlight on the lit edge, the specular part of the rim.
                shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .clear, .clear, .white.opacity(0.25)],
                                                  startPoint: .topLeading, endPoint: .bottomTrailing),
                                   lineWidth: 0.75)
            }
            .opacity(min(1, 0.32 * intensity))
            .blendMode(.plusLighter)
            .clipShape(shape)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func channel(_ color: Color, x: Double, y: Double) -> some View {
        shape.strokeBorder(LinearGradient(colors: [color, color.opacity(0.15), color.opacity(0.15), color],
                                          startPoint: .topLeading, endPoint: .bottomTrailing),
                           lineWidth: 1.4)
            .blur(radius: 0.5)
            .offset(x: x, y: y)
    }
}

/// The glass behind a whole window, edge to edge under the hidden title bar. The window itself has
/// a clear background, so what is behind the window shows through, blurred. Under Reduce
/// Transparency it is the opaque window background.
struct HQWindowGlass: View {
    var body: some View {
        Color.clear
            .hqGlass(in: .rect(cornerRadius: HQRadius.window, style: .continuous))
            .ignoresSafeArea()
    }
}
