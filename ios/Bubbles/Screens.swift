import SwiftUI
import Speech
import AVFoundation
import EventKit

@main struct BubblesApp: App {
    @State var app = AppModel()
    var body: some Scene {
        WindowGroup {
            Group {
                if app.onboarded { ScanView() } else { OnboardingView() }
            }
            .environment(app)
            .preferredColorScheme(.dark)
            #if DEBUG
            // Debug: `-ui card|edit|caught` opens that screen on launch (simulator screenshots).
            .task {
                let a = ProcessInfo.processInfo.arguments
                guard let i = a.firstIndex(of: "-ui"), i + 1 < a.count else { return }
                try? await Task.sleep(for: .seconds(1.5))
                switch a[i + 1] {
                case "card": app.selected = Demo.people[0]
                case "caught": app.showCaught = true
                case "astro":   // fill this phone with the astrophysics PhD test profile (all 8 interview lines)
                    let today = InterviewView.endOfToday
                    app.updateProfile(name: app.name.isEmpty ? "Dhyan" : app.name, lines: [
                        ProfileLine(kind: .identity, text: "Astrophysics PhD, final year.", source: "interview", topic: "Branch & year"),
                        ProfileLine(kind: .identity, text: "Into exoplanets, orbital mechanics and space telescopes.", source: "interview", topic: "Interests"),
                        ProfileLine(kind: .identity, text: "Astrophotography and rock climbing on weekends.", source: "interview", topic: "Hobbies"),
                        ProfileLine(kind: .plan, text: "Running telescope data simulations for my thesis today.", source: "interview", expiresAt: today, topic: "Today"),
                        ProfileLine(kind: .identity, text: "Finding exoplanet atmospheres with machine learning.", source: "interview", topic: "Excited about"),
                        ProfileLine(kind: .offer, text: "I can explain orbital mechanics or telescope data in five minutes.", source: "interview", topic: "Can help with"),
                        ProfileLine(kind: .ask, text: "I need help speeding up my Python ML pipeline.", source: "interview", topic: "Needs help with"),
                        ProfileLine(kind: .identity, text: "I host stargazing nights on the roof every Friday.", source: "interview", topic: "More about me"),
                    ])
                case "card7": app.selected = Person(id: "debug-7", name: "Arjun Rao", sentence: "I need help using ML to estimate satellite position.", kind: .ask, score: 91, lines: [
                    ProfileLine(kind: .identity, text: "Aerospace engineering, PhD 2nd year."),
                    ProfileLine(kind: .identity, text: "Into spacecraft guidance and orbital mechanics."),
                    ProfileLine(kind: .identity, text: "Rock climbing and astrophotography on weekends."),
                    ProfileLine(kind: .plan, text: "Running satellite simulations for my thesis today.", expiresAt: Date().addingTimeInterval(3600)),
                    ProfileLine(kind: .plan, text: "Old plan that already expired.", expiresAt: Date().addingTimeInterval(-60)),
                    ProfileLine(kind: .identity, text: "Building autonomous docking for small satellites."),
                    ProfileLine(kind: .offer, text: "I can explain orbital mechanics in five minutes."),
                    ProfileLine(kind: .ask, text: "I need help using ML to estimate a satellite's position.")])
                case "edit": NotificationCenter.default.post(name: .init("debugEdit"), object: nil)
                default: break
                }
            }
            #endif
            .sheet(item: Binding(get: { app.selected }, set: { app.selected = $0 })) { CardView(person: $0).environment(app) }
            .sheet(isPresented: Binding(get: { app.showCaught }, set: { app.showCaught = $0 })) { CaughtView().environment(app) }
            .overlay(alignment: .top) {
                if let t = app.toast {
                    Text(t).font(Ink.bangers(20)).tracking(0.7).foregroundStyle(Ink.ink)
                        .padding(.horizontal, 16).padding(.vertical, 10).mangaPanel(radius: 14)
                        .padding(.top, 110).padding(.horizontal, 20)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

// MARK: - Card

struct CardView: View {
    @Environment(AppModel.self) var app
    @Environment(\.dismiss) var dismiss
    let person: Person

    private var initials: String {
        let i = person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return i.isEmpty ? "?" : i
    }
    private var caught: Bool { app.catches.contains { $0.id == person.id } }

    /// Lines worth showing under the headline: not expired, not a rewording of the headline, no duplicates.
    private var sections: [(LineKind, [String])] {
        let now = Date()
        func words(_ t: String) -> Set<String> { Set(t.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 }) }
        let head = words(person.sentence)
        var seen = Set<String>()
        let order: [LineKind] = [.identity, .offer, .ask, .looking_for, .plan]
        return order.compactMap { k in
            let ls = person.lines.filter { $0.kind == k && ($0.expiresAt ?? .distantFuture) > now }.map(\.text).filter { t in
                let w = words(t)
                let overlap = w.isEmpty ? 0 : Double(w.intersection(head).count) / Double(min(w.count, max(head.count, 1)))
                return overlap < 0.7 && seen.insert(t.lowercased()).inserted
            }
            return ls.isEmpty ? nil : (k, ls)
        }
    }
    private func title(_ k: LineKind) -> String {
        switch k {
        case .identity: "About"
        case .offer: "Can help with"
        case .ask: "Needs help with"
        case .looking_for: "Looking for"
        case .plan: "Plans"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header: avatar, name, match.
                HStack(spacing: 14) {
                    Text(initials).font(Ink.bangers(26)).foregroundStyle(.white)
                        .frame(width: 60, height: 60).background(Circle().fill(Ink.red))
                        .overlay(Circle().stroke(Ink.ink, lineWidth: 3))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(person.name.isEmpty ? "Someone nearby" : person.name)
                            .font(Ink.bangers(30)).tracking(1).lineLimit(1).minimumScaleFactor(0.6)
                        HStack(spacing: 8) {
                            MatchBadge(score: person.score)
                            Text(person.rarity.rawValue.uppercased()).font(Ink.bangers(13)).tracking(0.8).opacity(0.6)
                        }
                    }
                    Spacer(minLength: 0)
                }

                // The bubble line: why they matter to you.
                VStack(alignment: .leading, spacing: 6) {
                    Text("WHY MEET").font(Ink.bangers(14)).tracking(1).foregroundStyle(Ink.red)
                    Text(person.sentence).font(Ink.bangers(24)).tracking(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading).mangaPanel(radius: 14)

                ForEach(sections, id: \.0) { k, texts in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title(k).uppercased()).font(Ink.bangers(16)).tracking(1).foregroundStyle(Ink.red)
                        ForEach(texts, id: \.self) { t in
                            Text("•  " + t).font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .foregroundStyle(Ink.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22).padding(.top, 26).padding(.bottom, 12)
        }
        // Actions always visible, even on long profiles.
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 14) {
                MangaButton(title: "WAVE") { app.wave(person); dismiss() }
                MangaButton(title: caught ? "CAUGHT ✓" : "CATCH", filled: false) { app.catchPerson(person); dismiss() }
                    .disabled(caught).opacity(caught ? 0.6 : 1)
            }
            .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 8)
            .background(Color.white.ignoresSafeArea().overlay(alignment: .top) { Rectangle().fill(Ink.ink).frame(height: 2) })
        }
        .background(Halftone().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .environment(\.colorScheme, .light)
    }
}

// MARK: - Caught

struct CaughtView: View {
    @Environment(AppModel.self) var app
    var body: some View {
        NavigationStack {
            ScrollView {
                if app.catches.isEmpty {
                    Text("Tap a bubble, then CATCH.").font(Ink.bangers(22)).foregroundStyle(.secondary).padding(.top, 80)
                }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 18) {
                    ForEach(app.catches) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(c.person.name).font(Ink.bangers(18)).lineLimit(1)
                                Spacer()
                                Circle().fill(c.person.rarity.fill).frame(width: 12, height: 12).overlay(Circle().stroke(Ink.ink, lineWidth: 2))
                            }
                            Text(c.person.sentence).font(Ink.bangers(15)).tracking(0.5).lineLimit(4)
                            Text("\(c.person.score)% · \(c.person.rarity.rawValue.uppercased())").font(Ink.bangers(12)).foregroundStyle(Ink.red)
                        }
                        .foregroundStyle(Ink.ink).padding(12).frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                        .mangaPanel(radius: 12)
                        .onTapGesture { app.showCaught = false; app.selected = c.person }
                    }
                }.padding(16)
            }
            .navigationTitle("Caught")
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Environment(AppModel.self) var app
    enum Step { case name, photo, interview, review, calendar }
    @State private var typed = false
    @State private var step = Step.name
    @State private var name = ""
    @State private var lines: [ProfileLine] = []

    var body: some View {
        ZStack {
            Halftone().ignoresSafeArea().opacity(0.95)
            VStack(alignment: .leading, spacing: 18) {
                switch step {
                case .name:
                    Text("BUBBLES").font(Ink.bangers(64)).foregroundStyle(Ink.red)
                    Text("What's your name?").font(Ink.bangers(28))
                    TextField("Name", text: $name).font(.system(size: 22, weight: .semibold)).padding(12).mangaPanel(radius: 10)
                        .textInputAutocapitalization(.words).submitLabel(.next)
                    Spacer()
                    MangaButton(title: "START INTERVIEW") { typed = false; step = .photo }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    MangaButton(title: "TYPE MY LINES", filled: false) {
                        lines = [ProfileLine(kind: .identity, text: ""), ProfileLine(kind: .offer, text: ""), ProfileLine(kind: .ask, text: "")]
                        typed = true; step = .photo
                    }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                case .photo:
                    SelfieStep { f in
                        if let f { app.face = f }
                        step = typed ? .review : .interview
                    }
                case .interview:
                    InterviewView(name: name) { lines = $0; step = .review }
                case .review:
                    ReviewView(lines: $lines) { step = .calendar }
                case .calendar:
                    CalendarStep { plans in
                        app.finishOnboarding(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                             lines: (lines + plans).filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
                    }
                }
            }
            .foregroundStyle(Ink.ink).padding(24).padding(.top, 30)
        }
        .preferredColorScheme(.light)
    }
}

struct ReviewView: View {
    @Binding var lines: [ProfileLine]
    let done: () -> Void
    var body: some View {
        Text("YOUR LINES").font(Ink.bangers(34))
        Text("One sentence each. People see the one that matters most to them.").font(.system(size: 14))
        ScrollView {
            VStack(spacing: 14) {
                ForEach($lines) { $l in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if let topic = l.topic, !topic.isEmpty {
                                Text(topic.uppercased()).font(Ink.bangers(16)).tracking(0.8).foregroundStyle(Ink.red)
                            } else {
                                Picker("", selection: $l.kind) { ForEach(LineKind.allCases) { Text($0.title).tag($0) } }
                                    .tint(Ink.red).labelsHidden()
                            }
                            Spacer()
                            Button { lines.removeAll { $0.id == l.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Ink.ink) }
                        }
                        TextField("One sentence", text: $l.text, axis: .vertical).font(.system(size: 17, weight: .medium))
                    }.padding(12).mangaPanel(radius: 10)
                }
                Button("+ ADD LINE") { lines.append(ProfileLine(kind: .offer, text: "")) }.font(Ink.bangers(20)).foregroundStyle(Ink.red)
            }.padding(4)
        }
        MangaButton(title: "SAVE") { done() }.disabled(lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
}

/// Spoken interview: AI asks (TTS), user answers by voice (on-device speech) or by typing.
struct InterviewView: View {
    let name: String
    var cancel: (() -> Void)? = nil
    let done: ([ProfileLine]) -> Void
    @State private var turns: [(q: String, a: String)] = []
    @State private var question = ""
    @State private var answer = ""
    @State private var loading = true
    @State private var mic = Mic()
    private let voice = AVSpeechSynthesizer()

    var body: some View {
        HStack {
            Text("INTERVIEW").font(Ink.bangers(34))
            Spacer()
            if let cancel { Button { mic.stop(); voice.stopSpeaking(at: .immediate); cancel() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 28)) } }
        }
        HStack {
            Text("Question \(min(turns.count + 1, Self.questions.count)) of \(Self.questions.count)\(optional ? " · optional" : "")").font(Ink.bangers(16)).foregroundStyle(Ink.red)
            Spacer()
            if !turns.isEmpty && !loading {
                Button { back() } label: { Label("BACK", systemImage: "chevron.left").font(Ink.bangers(16)) }.foregroundStyle(Ink.ink)
            }
        }
        ProgressView(value: Double(turns.count), total: Double(Self.questions.count)).tint(Ink.red)
        Text(loading ? "…" : question).font(Ink.bangers(26)).tracking(0.8).frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).mangaPanel()
        TextField("Your answer", text: $answer, axis: .vertical).font(.system(size: 18)).lineLimit(3...8)
            .accessibilityIdentifier("answer")
            .padding(12).mangaPanel(radius: 10)
        Spacer()
        if let n = mic.note { Text(n).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.red) }
        MangaButton(title: mic.listening ? "STOP LISTENING" : "ANSWER BY VOICE", filled: !mic.listening) {
            if mic.listening { mic.stop() } else { voice.stopSpeaking(at: .immediate); mic.start { answer = $0 } }
        }
        let empty = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        MangaButton(title: optional ? (empty ? "SKIP & FINISH" : "FINISH") : "NEXT", filled: false) { Task { await next() } }
            .disabled((empty && !optional) || loading)
        .task { await ask() }
    }

    private func ask() async {
        loading = true
        let body: [String: Any] = ["name": name, "turns": turns.map { ["q": $0.q, "a": $0.a] }]
        var r: [String: Any] = [:]
        // Fixed questions, asked instantly; Claude only turns the answers into lines at the end.
        if turns.count < Self.questions.count { r = ["question": Self.questions[turns.count]] }
        else if Config.online { r = (try? await Backend.function("interview", body)) ?? [:] }
        if r["done"] as? Bool != true && (r["question"] as? String ?? "").isEmpty { r = offline() }
        if r["done"] as? Bool == true {
            var ls = lines(from: r)
            if ls.isEmpty { ls = lines(from: offline(force: true)) }
            return done(ls)
        }
        question = r["question"] as? String ?? "Tell me about yourself."
        loading = false
        let u = AVSpeechUtterance(string: question); u.rate = 0.52
        voice.speak(u)
    }
    /// Previous question, with its answer back in the box.
    private func back() {
        mic.stop(); voice.stopSpeaking(at: .immediate)
        guard let last = turns.popLast() else { return }
        question = last.q; answer = last.a
    }
    private func next() async {
        mic.stop()
        turns.append((question, answer)); answer = ""
        await ask()
    }
    private func lines(from r: [String: Any]) -> [ProfileLine] {
        (r["lines"] as? [[String: Any]] ?? []).compactMap { l -> ProfileLine? in
            guard let k = LineKind(rawValue: l["kind"] as? String ?? ""), let t = (l["text"] as? String)?.oneSentence, !t.isEmpty else { return nil }
            // "Today" answers are plans: they expire at midnight so tomorrow's bubble isn't stale.
            return ProfileLine(kind: k, text: t, source: "interview", expiresAt: k == .plan ? Self.endOfToday : nil, topic: l["topic"] as? String)
        }
    }
    /// Same list as supabase/functions/interview. Keep them in sync.
    static let questions = [
        "Which branch or major are you from, and which year?",
        "What are you interested in?",
        "What are your hobbies?",
        "What are you up to today?",
        "What's a project or idea you're excited about right now?",
        "What could you help someone with, or teach in five minutes?",
        "Anything you need help with, or someone you'd like to meet?",
        "Anything else I should know about you?",
    ]
    /// The last question is optional.
    private var optional: Bool { turns.count == Self.questions.count - 1 }
    /// Label for each question's line, same order as `questions` (and the server's TOPICS).
    static let topics = ["Branch & year", "Interests", "Hobbies", "Today", "Excited about", "Can help with", "Needs help with", "More about me"]
    static var endOfToday: Date { Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))! }

    /// No network: one line per answer from simple templates.
    private func offline(force: Bool = false) -> [String: Any] {
        if !force && turns.count < Self.questions.count { return ["question": Self.questions[turns.count]] }
        let tpl: [(String, String)] = [("identity", "I'm in %@."), ("identity", "I'm into %@."), ("identity", "In my free time: %@."), ("plan", "Today I'm %@."), ("identity", "Excited about %@."), ("offer", "I can help with %@."), ("ask", "%@"), ("identity", "%@")]
        let out = turns.enumerated().compactMap { i, t -> [String: String]? in
            let a = t.a.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            guard !a.isEmpty else { return nil }
            let (k, f) = i < tpl.count ? tpl[i] : ("identity", "%@")
            return ["kind": k, "text": String(format: f, a).oneSentence, "topic": i < Self.topics.count ? Self.topics[i] : ""]
        }
        return ["done": true, "lines": out]
    }
}

@Observable final class Mic {
    var listening = false
    var note: String?
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private let recognizer = SFSpeechRecognizer()
    @ObservationIgnored private var starting = false

    func start(_ onText: @escaping (String) -> Void) {
        guard !listening, !starting else { return }   // double taps would install two taps and crash
        starting = true
        SFSpeechRecognizer.requestAuthorization { st in
            AVAudioApplication.requestRecordPermission { ok in
                DispatchQueue.main.async {
                    self.starting = false
                    if st == .authorized && ok { self.begin(onText) }
                    else { self.note = "Mic or speech access is off (Settings > Bubbles). You can type instead." }
                }
            }
        }
    }
    private func begin(_ onText: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { note = "Speech recognition unavailable right now. Type instead."; return }
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { note = "No microphone input. Type instead."; return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { b, _ in req.append(b) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); note = "Could not start the mic. Type instead."; return }
        note = nil
        listening = true
        task = recognizer.recognitionTask(with: req) { r, e in
            if let r { DispatchQueue.main.async { onText(r.bestTranscription.formattedString) } }
            if e != nil || r?.isFinal == true { DispatchQueue.main.async { self.stop() } }
        }
    }
    func stop() {
        guard listening else { return }
        engine.stop(); engine.inputNode.removeTap(onBus: 0); task?.finish(); task = nil; listening = false
    }
}

/// Optional: EventKit next 7 days -> Claude plan lines -> user ticks which go public.
struct CalendarStep: View {
    let done: ([ProfileLine]) -> Void
    @State private var suggestions: [(line: ProfileLine, on: Bool)] = []
    @State private var loading = false
    @State private var asked = false

    var body: some View {
        Text("PLANS").font(Ink.bangers(34))
        Text("Add plan lines from your calendar, like \"Playing tennis Saturday morning\". Event details are never stored.")
            .font(.system(size: 14))
        if loading { ProgressView().padding() }
        ScrollView {
            VStack(spacing: 10) {
                ForEach(suggestions.indices, id: \.self) { i in
                    Button { suggestions[i].on.toggle() } label: {
                        HStack {
                            Image(systemName: suggestions[i].on ? "checkmark.square.fill" : "square").foregroundStyle(Ink.red)
                            Text(suggestions[i].line.text).font(.system(size: 16, weight: .medium)).multilineTextAlignment(.leading)
                            Spacer()
                        }.padding(12).mangaPanel(radius: 10)
                    }.buttonStyle(.plain)
                }
            }.padding(4)
        }
        if !asked { MangaButton(title: "READ MY CALENDAR") { Task { await load() } } }
        MangaButton(title: asked ? "DONE" : "SKIP", filled: asked) { done(suggestions.filter(\.on).map(\.line)) }
    }

    private func load() async {
        asked = true; loading = true; defer { loading = false }
        let store = EKEventStore()
        guard (try? await store.requestFullAccessToEvents()) == true else { return }
        let events = store.events(matching: store.predicateForEvents(withStart: Date(), end: Date().addingTimeInterval(7 * 86400), calendars: nil))
            .filter { !$0.isAllDay || true }.prefix(30)
        let iso = ISO8601DateFormatter()
        let list: [[String: Any]] = events.map { ["title": $0.title ?? "", "start": iso.string(from: $0.startDate), "end": iso.string(from: $0.endDate)] }
        var out: [[String: Any]] = []
        if Config.online, let r = try? await Backend.function("calendar_lines", ["events": list]) { out = r["lines"] as? [[String: Any]] ?? [] }
        if out.isEmpty { out = list.prefix(5).map { ["text": $0["title"]!, "expires_at": $0["end"]!] } }
        suggestions = out.compactMap { l in
            guard let t = l["text"] as? String, !t.isEmpty else { return nil }
            return (ProfileLine(kind: .plan, text: t, source: "calendar", expiresAt: (l["expires_at"] as? String).flatMap(iso.date)), false)
        }
    }
}

// MARK: - Edit profile (tap your name chip on the scan screen)

struct EditProfileView: View {
    @Environment(AppModel.self) var app
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var lines: [ProfileLine] = []
    @State private var photo = false
    @State private var interview = false
    @State private var loaded = false
    @State private var saved = false
    @State private var original: (String, [ProfileLine]) = ("", [])
    private var changed: Bool { name != original.0 || lines.map(\.text) != original.1.map(\.text) || lines.map(\.kind) != original.1.map(\.kind) }
    private func save() {
        saved = true
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        app.updateProfile(name: n.isEmpty ? app.name : n,
                          lines: lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    var body: some View {
        ZStack {
            Halftone().ignoresSafeArea().opacity(0.95)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("EDIT PROFILE").font(Ink.bangers(34))
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 28)) }
                        .accessibilityLabel("Close").accessibilityIdentifier("editClose")
                }
                TextField("Name", text: $name).font(.system(size: 20, weight: .semibold)).padding(12).mangaPanel(radius: 10)
                    .textInputAutocapitalization(.words)
                HStack(spacing: 10) {
                    Button { photo = true } label: {
                        Label(app.face == nil ? "ADD PHOTO" : "RETAKE PHOTO", systemImage: app.face == nil ? "camera" : "checkmark.circle.fill")
                            .font(Ink.bangers(17)).tracking(0.8).frame(maxWidth: .infinity)
                            .foregroundStyle(.white).padding(.vertical, 10).background(Capsule().fill(app.face == nil ? Ink.red : Ink.ink))
                    }
                    Button { interview = true } label: {
                        Label("REDO INTERVIEW", systemImage: "mic.fill").font(Ink.bangers(17)).tracking(0.8).frame(maxWidth: .infinity)
                            .foregroundStyle(.white).padding(.vertical, 10).background(Capsule().fill(Ink.ink))
                    }
                }
                ReviewView(lines: $lines) { save(); dismiss() }
            }
            .foregroundStyle(Ink.ink).padding(24)
        }
        .preferredColorScheme(.light)
        // Load once: onAppear also fires when the photo/interview sheet closes, which used to wipe new lines.
        .onAppear { if !loaded { loaded = true; name = app.name; lines = app.lines; original = (app.name, app.lines) } }
        // Closing with ✕ or a swipe down keeps the changes instead of silently dropping them.
        .onDisappear { if !saved && !photo && !interview && changed { save() } }
        .sheet(isPresented: $interview) {
            ZStack { Halftone().ignoresSafeArea().opacity(0.95)
                VStack(alignment: .leading, spacing: 18) {
                    InterviewView(name: name.isEmpty ? app.name : name, cancel: { interview = false }) { new in lines = new; interview = false }
                }.foregroundStyle(Ink.ink).padding(24)
            }.preferredColorScheme(.light)
        }
        .sheet(isPresented: $photo) {
            ZStack { Halftone().ignoresSafeArea().opacity(0.95)
                SelfieStep(skippable: false) { f in app.setFace(f); photo = false }.foregroundStyle(Ink.ink).padding(24)
            }.preferredColorScheme(.light)
        }
    }
}
