import SwiftUI

/// The Fenrir wolf head: same outline as design/fenrir-icon.svg, on a 100-unit grid.
struct FenrirMark: Shape {
    private static let head: [(Double, Double)] = [
        (50, 24), (63, 28), (84, 4), (90, 40), (97, 58), (82, 63), (88, 82), (68, 77), (59, 97), (50, 86),
        (41, 97), (32, 77), (12, 82), (18, 63), (3, 58), (10, 40), (16, 4), (37, 28),
    ]
    private static let eyes: [[(Double, Double)]] = [[(60, 47), (78, 43), (72, 55)], [(40, 47), (22, 43), (28, 55)]]
    private static let nose: [(Double, Double)] = [(43, 68), (57, 68), (50, 77)]

    /// Head only (eyes and nose are cut out with the even-odd rule).
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 100
        let ox = rect.midX - 50 * k, oy = rect.midY - 50 * k
        var p = Path()
        for poly in [Self.head] + Self.eyes + [Self.nose] {
            p.addLines(poly.map { CGPoint(x: ox + $0.0 * k, y: oy + $0.1 * k) })
            p.closeSubpath()
        }
        return p
    }
}

/// The mark on its rounded tile, as in the app icon.
struct FenrirBadge: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.17, green: 0.23, blue: 0.33), Color(red: 0.07, green: 0.10, blue: 0.17)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(FenrirMark().fill(Color(red: 0.93, green: 0.95, blue: 0.99), style: FillStyle(eoFill: true)).padding(size * 0.14))
    }
}
