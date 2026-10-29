import SwiftUI

enum Layout {
    /// How big the photos hang, from Size in the menu bar. The clip, the rope
    /// and the glass frame keep their size; the photos and the room they take
    /// grow or shrink. Medium is the original size.
    enum Size: String, CaseIterable {
        case small, medium, large

        var scale: CGFloat {
            switch self {
            case .small: 0.8
            case .medium: 1
            case .large: 1.35
            }
        }
    }

    static var size: Size {
        get { Size(rawValue: ClipSettings.defaults.string(forKey: "lineSize") ?? "") ?? .medium }
        set { ClipSettings.defaults.set(newValue.rawValue, forKey: "lineSize") }
    }

    static var photoMaxHeight: CGFloat { (104 * size.scale).rounded() }
    static var cardWidth: CGFloat { (150 * size.scale).rounded() }
    static var spacing: CGFloat { cardWidth + 24 }
    static var panelHeight: CGFloat { photoMaxHeight + 106 }
    static let ropeTop: CGFloat = 10
    static let pinAbove: CGFloat = 9.5

    /// The rope hangs as a parabola from edge to edge of the screen.
    static func sag(width: CGFloat) -> CGFloat { min(30, width * 0.018) }

    static func ropeY(x: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return ropeTop }
        let f = x / width
        return ropeTop + 4 * sag(width: width) * f * (1 - f)
    }

    /// Photos hang `spacing` apart, centred. When there are more than the
    /// `visible` that fit: with Keep on line set, they keep their spacing,
    /// the newest stays where the last one would hang on a full line, and
    /// `scroll` brings older ones in from the left. Otherwise (a line hung
    /// on a wider screen) they move closer together so none is past the edge.
    static func x(index: Int, count: Int, width: CGFloat, visible: Int, scroll: CGFloat) -> CGFloat {
        if count > visible {
            let newest = width / 2 + CGFloat(visible - 1) * spacing / 2
            return newest - CGFloat(count - 1 - index) * spacing + scroll
        }
        let gaps = CGFloat(max(count - 1, 0))
        let step = gaps > 0 ? min(spacing, max(0, width - 200) / gaps) : spacing
        return width / 2 - gaps * step / 2 + CGFloat(index) * step
    }
}

struct LineView: View {
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let contentWidth = max(200, width - 160)
            let live = line.items.filter { !$0.falling }
            ZStack(alignment: .topLeading) {
                Rope(width: width)
                NewLayerClip(line: line)
                    .position(x: 80, y: Layout.ropeY(x: 80, width: width) + 29)

                ForEach(Array(live.enumerated()), id: \.element.id) { index, item in
                    let x = 160 + Layout.x(index: index, count: live.count + 1, width: contentWidth,
                                          visible: line.visibleCount, scroll: line.scroll)
                    let ropeY = Layout.ropeY(x: x, width: width)
                    PeggedView(item: item, line: line)
                        .frame(width: Layout.cardWidth, height: Layout.panelHeight - ropeY, alignment: .top)
                        // Photos scrolled towards an edge fade out before they reach it.
                        .opacity(min(1, max(0, min(x - 160, width - x) / 90)))
                        .position(x: x, y: ropeY - Layout.pinAbove + (Layout.panelHeight - ropeY) / 2)
                }
                let addX = 160 + Layout.x(index: live.count, count: live.count + 1, width: contentWidth,
                                         visible: line.visibleCount, scroll: line.scroll)
                EmptyNoteClip(action: { line.onNewNote() })
                    .position(x: addX, y: Layout.ropeY(x: addX, width: width) + 19)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.78), value: live.map(\.id))
            .animation(.easeInOut(duration: 0.3), value: line.items.isEmpty)
            // Tucked away, the whole line waits above the top edge and slides
            // out from under the menu bar, the way an auto-hiding Dock does.
            .offset(y: line.revealed ? 0 : -(Layout.panelHeight + 12))
            .animation(line.revealed ? .spring(response: 0.42, dampingFraction: 0.82)
                                     : .easeIn(duration: 0.22), value: line.revealed)
        }
        .onPreferenceChange(HitRectsKey.self) { rects in
            line.hitRects = rects
        }
    }
}

private struct NewLayerClip: View {
    @ObservedObject var line: Line
    var body: some View {
        Button(action: { line.onNewLayer() }) {
            VStack(spacing: 2) {
                Clothespin().frame(width: 38, height: 30)
                Text(L("New layer")).font(.system(size: 11, weight: .medium))
                Text(line.layerPosition)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(width: 140, height: 82)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Create an empty layer; Shift+Down switches layers"))
        .accessibilityLabel(L("New layer"))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: HitRectsKey.self,
                                   value: [Line.newLayerClipID: geometry.frame(in: .global)])
        })
    }
}

private struct EmptyNoteClip: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Clothespin().frame(width: 38, height: 30)
                Text(L("New note"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 90, height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Click the empty clip to write a note"))
        .accessibilityLabel(L("New note"))
        .background(GeometryReader { geometry in
            Color.clear.preference(key: HitRectsKey.self,
                                   value: [Line.emptyClipID: geometry.frame(in: .global)])
        })
    }
}

private struct Hint: View {
    var body: some View {
        Text(L("Take a screenshot and it will hang here"))
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
    }
}

/// A thin, neutral line: a mid gray core with a faint highlight and a soft
/// shadow, so it reads on light and dark backgrounds alike. It fades out at
/// both ends so it seems to come from beyond the screen.
struct Rope: View {
    let width: CGFloat

    private var path: Path {
        Path { p in
            let top = Layout.ropeTop
            p.move(to: CGPoint(x: -20, y: top))
            p.addQuadCurve(
                to: CGPoint(x: width + 20, y: top),
                control: CGPoint(x: width / 2, y: top + 2 * Layout.sag(width: width)))
        }
    }

    var body: some View {
        ZStack {
            path.stroke(Color.black.opacity(0.22), lineWidth: 1.4).offset(y: 1.2).blur(radius: 1.2)
            path.stroke(Color(white: 0.55), lineWidth: 1.2)
            path.stroke(Color.white.opacity(0.45), lineWidth: 0.4).offset(y: -0.35)
        }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.08),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        )
        .allowsHitTesting(false)
    }
}

struct HitRectsKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
