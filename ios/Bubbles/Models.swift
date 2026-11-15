import SwiftUI

enum Config {
    // Fill these after `supabase link` + deploy. Empty URL = offline (demo + local profile only).
    static let supabaseURL = "https://xflovlbpirytlyymekds.supabase.co"
    static let supabaseAnonKey = "sb_publishable_Jte303RgmuxnBz1C-y-0NQ_eZBCGo_C"   // publishable: safe in the app
    static var online: Bool { !supabaseURL.isEmpty }
}

enum LineKind: String, Codable, CaseIterable, Identifiable {
    case identity, offer, ask, looking_for, plan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .identity: "Who I am"
        case .offer: "I can help with"
        case .ask: "I need help with"
        case .looking_for: "Looking for"
        case .plan: "Plans"
        }
    }
}

struct ProfileLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: LineKind
    var text: String
    var source: String = "manual"
    var expiresAt: Date? = nil
    /// Which interview question it answers ("Hobbies", "Today"…), shown instead of the generic kind. Local only.
    var topic: String? = nil
    enum CodingKeys: String, CodingKey { case kind, text, source, expiresAt = "expires_at", topic }
}

enum Rarity: String, Codable {
    case Legendary, Rare, Common
    init(score: Int) { self = score >= 90 ? .Legendary : score >= 75 ? .Rare : .Common }
    var fill: Color { switch self { case .Legendary: Ink.gold; case .Rare: Ink.red; case .Common: Ink.ink } }
    var text: Color { self == .Legendary ? Ink.ink : .white }
}

/// One person we know something about (from match or demo seed).
struct Person: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var sentence: String
    var kind: LineKind
    var score: Int
    var lines: [ProfileLine]
    var rarity: Rarity { Rarity(score: score) }
}

struct Catch: Codable, Identifiable, Hashable {
    var id: String { person.id }
    var person: Person
    var date: Date
}

enum Demo {
    static let people: [Person] = [
        Person(id: "demo-1", name: "Maya Chen", sentence: "I'm an aerospace researcher working on satellite autonomy.", kind: .identity, score: 94,
               lines: [ProfileLine(kind: .identity, text: "I'm an aerospace researcher working on satellite autonomy."),
                       ProfileLine(kind: .offer, text: "Happy to talk orbital mechanics with anyone."),
                       ProfileLine(kind: .plan, text: "Running the Saturday morning trail loop.")]),
        Person(id: "demo-2", name: "Leo Park", sentence: "How would I add a Redis cache to my project?", kind: .ask, score: 81,
               lines: [ProfileLine(kind: .identity, text: "Freshman in CS, building my first web app."),
                       ProfileLine(kind: .ask, text: "How would I add a Redis cache to my project?")]),
        Person(id: "demo-3", name: "Sam Ortiz", sentence: "Need a teammate who knows ARKit, demo is tomorrow.", kind: .looking_for, score: 67,
               lines: [ProfileLine(kind: .looking_for, text: "Need a teammate who knows ARKit, demo is tomorrow."),
                       ProfileLine(kind: .offer, text: "I can design your pitch deck in an hour.")]),
    ]
}
