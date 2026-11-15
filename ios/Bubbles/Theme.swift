import SwiftUI

enum Ink {
    static let ink = Color(red: 0x11/255, green: 0x11/255, blue: 0x11/255)
    static let red = Color(red: 0xE4/255, green: 0, blue: 0x2B/255)
    static let gold = Color(red: 1, green: 0xB8/255, blue: 0)
    static let chip = Color(red: 0x11/255, green: 0x11/255, blue: 0x11/255).opacity(0.78)
    static func bangers(_ size: CGFloat) -> Font { .custom("Bangers-Regular", size: size) }
}

/// White paper with 1.1pt dots on a 6pt grid.
struct Halftone: View {
    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var p = Path()
            for x in stride(from: 3.0, to: size.width, by: 6) {
                for y in stride(from: 3.0, to: size.height, by: 6) {
                    p.addEllipse(in: CGRect(x: x - 1.1, y: y - 1.1, width: 2.2, height: 2.2))
                }
            }
            ctx.fill(p, with: .color(.black.opacity(0.14)))
        }
    }
}

/// Manga panel: halftone fill, 3pt ink border, 4pt hard shadow.
struct MangaPanel: ViewModifier {
    var radius: CGFloat = 22
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerSize: CGSize(width: radius * 1.18, height: radius), style: .continuous)
        content
            .background(Halftone().clipShape(shape))
            .overlay(shape.stroke(Ink.ink, lineWidth: 3))
            .background(shape.fill(Ink.ink).offset(x: 4, y: 4))
    }
}
extension View { func mangaPanel(radius: CGFloat = 22) -> some View { modifier(MangaPanel(radius: radius)) } }

struct MatchBadge: View {
    let score: Int
    var body: some View {
        let r = Rarity(score: score)
        Text("\(score)% MATCH")
            .font(Ink.bangers(14)).tracking(0.84)
            .foregroundStyle(r.text)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(r.fill))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Ink.ink, lineWidth: 2.5))
            .background(RoundedRectangle(cornerRadius: 3).fill(Ink.ink).offset(x: 3, y: 3))
    }
}

struct MangaButton: View {
    let title: String
    var filled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(Ink.bangers(24)).tracking(1)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .foregroundStyle(filled ? .white : Ink.ink)
                .background(RoundedRectangle(cornerRadius: 10).fill(filled ? Ink.red : .white))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Ink.ink, lineWidth: 3))
                .background(RoundedRectangle(cornerRadius: 10).fill(Ink.ink).offset(x: 4, y: 4))
        }.buttonStyle(.plain)
    }
}
