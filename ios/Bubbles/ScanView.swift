import SwiftUI
import UIKit
import ARKit

private let tilts: [Double] = [-3, 2.5, -1.5]
private let scanSeconds = 0.35
private let maxTextWidth: CGFloat = 236 - 32

/// Text size with balanced wrapping: narrowest width that keeps the same line count.
private func measure(_ s: String) -> CGSize {
    let font = UIFont(name: "Bangers-Regular", size: 20) ?? .boldSystemFont(ofSize: 20)
    let para = NSMutableParagraphStyle(); para.lineHeightMultiple = 1.1
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .kern: 0.7, .paragraphStyle: para]
    func size(_ w: CGFloat) -> CGSize {
        let r = (s as NSString).boundingRect(with: CGSize(width: w, height: 999), options: .usesLineFragmentOrigin, attributes: attrs, context: nil)
        return CGSize(width: ceil(r.width), height: ceil(r.height))
    }
    let full = size(maxTextWidth)
    var lo: CGFloat = 40, hi = maxTextWidth
    while hi - lo > 2 { let m = (lo + hi) / 2; if size(m).height > full.height { lo = m } else { hi = m } }
    return CGSize(width: size(hi).width + 2, height: full.height)
}
private var measureCache: [String: CGSize] = [:]
private func bubbleSize(_ s: String) -> CGSize {
    if let c = measureCache[s] { return c }
    let t = measure(s); let r = CGSize(width: t.width + 32, height: t.height + 25)
    measureCache[s] = r; return r
}

struct Placed: Identifiable {
    let id: Int; let person: Person; let slot: Int; let head: CGPoint
    var frame: CGRect; let scanning: Bool
}

/// Remembers bubble positions and identities across frames.
final class ScanState {
    var pos: [Int: CGPoint] = [:]
    var appeared: [Int: Date] = [:]     // when a bubble came into view
    var assign: [Int: String] = [:]     // demo: head track id -> demo person id
    var ids: [String: Int] = [:]        // live: person key -> stable bubble id
    var locating: [String] = []         // live: nearby users not on a face yet
    var lastLog = Date.distantPast
    var hits: [String: Int] = [:]       // live: "face|person" -> frames in a row it matched
    var recognized: [Int: String] = [:] // live: head track id -> person key, kept while the track lives
}

struct ScanView: View {
    @Environment(AppModel.self) var app
    @State var engine = HeadEngine()
    @State private var state = ScanState()
    @State private var takingPhoto = false
    @State private var editing = false

    var body: some View {
        ZStack {
            CameraBackground(engine: engine).id(engine.useAR).ignoresSafeArea()
            TimelineView(.animation) { _ in GeometryReader { geo in overlay(size: geo.size) } }
        }
        .ignoresSafeArea()
        .onAppear {
            engine.start(); app.ble.setScanning(true); UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear { engine.stop(); app.ble.setScanning(false); UIApplication.shared.isIdleTimerDisabled = false }
        .sheet(isPresented: $editing, onDismiss: { engine.resumeLive() }) { EditProfileView().environment(app) }
        .sheet(isPresented: $takingPhoto, onDismiss: { engine.resumeLive() }) {
            ZStack { Halftone().ignoresSafeArea().opacity(0.95)
                SelfieStep(skippable: false) { f in app.setFace(f); takingPhoto = false }
                    .foregroundStyle(Ink.ink).padding(24)
            }.preferredColorScheme(.light)
        }
    }

    @ViewBuilder private func overlay(size: CGSize) -> some View {
            let placed = layout(in: size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Canvas { ctx, _ in
                    for p in placed {
                        let tx = min(max(p.head.x - p.frame.minX, 18), p.frame.width - 18)
                        let tip = CGPoint(x: p.frame.minX + tx, y: p.frame.maxY + 9)
                        if p.head.y - tip.y > 10 {
                            var l = Path(); l.move(to: tip); l.addLine(to: CGPoint(x: p.head.x, y: p.head.y - 3))
                            ctx.stroke(l, with: .color(Ink.red), lineWidth: 1.5)
                        }
                        ctx.fill(Path(ellipseIn: CGRect(x: p.head.x - 3.5, y: p.head.y - 3.5, width: 7, height: 7)), with: .color(Ink.red))
                    }
                }.allowsHitTesting(false)
                ForEach(placed) { p in
                    BubbleView(person: p.person, scanning: p.scanning, tilt: tilts[p.slot % 3],
                               tailX: min(max(p.head.x - p.frame.minX, 18), p.frame.width - 18), size: p.frame.size)
                        .offset(x: p.frame.minX, y: p.frame.minY - 12)
                        .onTapGesture { app.selected = p.person }
                        .transition(.opacity.animation(.easeOut(duration: 0.18)))
                }
                chrome(placed: placed, size: size)
            }
    }

    private struct Anchor { let id: Int; let person: Person; let pt: CGPoint }

    /// Demo: the bundled people on detected heads (clip or live camera), left to right, sticky.
    private func demoAnchors(_ size: CGSize) -> [Anchor] {
        let alive = Set(engine.heads.map(\.id))
        state.assign = state.assign.filter { alive.contains($0.key) }
        var free = Demo.people.filter { p in !state.assign.values.contains(p.id) }
        for h in engine.heads.filter({ state.assign[$0.id] == nil }).sorted(by: { $0.x < $1.x }) where !free.isEmpty {
            state.assign[h.id] = free.removeFirst().id
        }
        let byID = Dictionary(uniqueKeysWithValues: Demo.people.map { ($0.id, $0) })
        return engine.heads.compactMap { h in
            state.assign[h.id].flatMap { byID[$0] }.map { Anchor(id: h.id, person: $0, pt: engine.toView(h.x, h.y, in: size)) }
        }
    }

    /// Live: each face's signature is matched to nearby users' photo signatures (read over Bluetooth).
    /// A recognised face keeps its name while its track lives, so walking people stay labelled.
    private func liveAnchors(_ size: CGSize) -> [Anchor] {
        let heads = engine.heads
        let headByID = Dictionary(uniqueKeysWithValues: heads.map { ($0.id, $0) })
        func view(_ h: HeadTrack) -> CGPoint { engine.toView(h.x, h.y, in: size) }

        var out: [Anchor] = []
        var used = Set<Int>()
        let all = app.matchedPeers
        func bubbleID(_ key: String) -> Int { state.ids[key] ?? { let n = 1000 + state.ids.count; state.ids[key] = n; return n }() }

        state.recognized = state.recognized.filter { headByID[$0.key] != nil }
        var sims: [(head: HeadTrack, peer: Pinnable, cos: Float)] = []
        for h in heads { guard let hs = h.sig else { continue }
            for p in all { if let ps = p.face { sims.append((h, p, FaceID.cosine(hs, ps))) } } }
        var donePeers = Set<String>()
        // Keep earlier recognitions while the score holds.
        for (hid, key) in state.recognized {
            guard let h = headByID[hid], let p = all.first(where: { $0.key == key }), !donePeers.contains(key),
                  let hs = h.sig, let ps = p.face, FaceID.cosine(hs, ps) >= Self.keepAt else { state.recognized[hid] = nil; continue }
            used.insert(hid); donePeers.insert(key)
        }
        // New: score >= matchAt, beats this person's other faces AND this face's other people by a margin,
        // for several frames in a row.
        var hitNow = Set<String>()
        for m in sims.sorted(by: { $0.cos > $1.cos }) where m.cos >= Self.matchAt {
            guard !used.contains(m.head.id), !donePeers.contains(m.peer.key) else { continue }
            let otherFace = sims.filter { $0.peer.key == m.peer.key && $0.head.id != m.head.id }.map(\.cos).max() ?? -1
            let otherPeer = sims.filter { $0.head.id == m.head.id && $0.peer.key != m.peer.key }.map(\.cos).max() ?? -1
            guard m.cos - max(otherFace, otherPeer) >= Self.margin else { continue }
            let k = "\(m.head.id)|\(m.peer.key)"
            hitNow.insert(k)
            let n = (state.hits[k] ?? 0) + 1
            state.hits[k] = n
            if n >= Self.framesNeeded { state.recognized[m.head.id] = m.peer.key; used.insert(m.head.id); donePeers.insert(m.peer.key) }
        }
        state.hits = state.hits.filter { hitNow.contains($0.key) }
        for (hid, key) in state.recognized {
            guard let h = headByID[hid], let p = all.first(where: { $0.key == key }) else { continue }
            out.append(Anchor(id: bubbleID(key), person: p.person, pt: view(h)))
        }
        if Date().timeIntervalSince(state.lastLog) > 1, !sims.isEmpty {
            state.lastLog = Date()
            print("[FACE] " + sims.sorted { $0.cos > $1.cos }.map { "\($0.peer.person.name)~face\($0.head.id)=\(String(format: "%.2f", $0.cos))" }.joined(separator: " ")
                  + " | shown: " + state.recognized.map { "face\($0.key)=\($0.value.suffix(6))" }.joined(separator: ","))
        }

        // Not recognised: status chip only, never a guessed face.
        for p in all where !donePeers.contains(p.key) {
            state.locating.append(p.face != nil ? "\(p.person.name) nearby · looking for their face" : "\(p.person.name) nearby · no photo yet")
        }
        return out
    }

    static let matchAt: Float = 0.65, keepAt: Float = 0.45, margin: Float = 0.1
    static let framesNeeded = 3

    private func layout(in size: CGSize) -> [Placed] {
        let W = size.width
        let now = Date()
        state.locating = []
        engine.recognize = !app.demo
        let anchors = app.demo ? demoAnchors(size) : liveAnchors(size)
        let shown = Set(anchors.map(\.id))
        state.pos = state.pos.filter { shown.contains($0.key) }
        state.appeared = state.appeared.filter { shown.contains($0.key) }
        for a in anchors where state.appeared[a.id] == nil { state.appeared[a.id] = now }

        struct Box { var h: CGPoint; var r: CGRect; let person: Person; let id: Int; let scanning: Bool }
        var boxes: [Box] = []
        for a in anchors {
            var pt = a.pt
            guard pt.x > -30, pt.x < W + 30 else { continue }
            pt.x = min(max(pt.x, 8), W - 8)
            let scanning = now.timeIntervalSince(state.appeared[a.id] ?? .distantPast) < scanSeconds
            let s = scanning ? CGSize(width: 90, height: 47) : bubbleSize(a.person.sentence)
            let hgt = s.height + 12   // badge reserve
            let left = min(max(10, pt.x - s.width / 2), W - 10 - s.width)
            boxes.append(Box(h: pt, r: CGRect(x: left, y: pt.y - 14 - hgt, width: s.width, height: hgt), person: a.person, id: a.id, scanning: scanning))
        }
        // Crowded layout (port of Renderer.render).
        boxes.sort { $0.h.x < $1.h.x }
        for i in boxes.indices.dropFirst() where boxes[i - 1].r.intersects(boxes[i].r) {
            boxes[i - 1].r.origin.x = max(10, min(boxes[i - 1].r.minX, boxes[i - 1].h.x - boxes[i - 1].r.width + 22))
            boxes[i].r.origin.x = min(W - 10 - boxes[i].r.width, max(boxes[i].r.minX, boxes[i].h.x - 22))
        }
        boxes.sort { $0.h.y > $1.h.y }
        for i in boxes.indices { for j in 0..<i {
            let a = boxes[j].r, b = boxes[i].r
            if a.minX < b.maxX && b.minX < a.maxX && b.maxY + 8 > a.minY { boxes[i].r.origin.y = a.minY - b.height - 8 }
        } }
        let slots = boxes.sorted { $0.id < $1.id }.map(\.id)
        return boxes.map { b in
            let target = b.r.origin
            let cur = state.pos[b.id].map { CGPoint(x: $0.x + (target.x - $0.x) * 0.45, y: $0.y + (target.y - $0.y) * 0.45) } ?? target
            state.pos[b.id] = cur
            var r = b.r; r.origin = cur; r.origin.y += 12; r.size.height -= 12
            return Placed(id: b.id, person: b.person, slot: slots.firstIndex(of: b.id) ?? 0, head: b.h, frame: r, scanning: b.scanning)
        }
    }

    @ViewBuilder private func chrome(placed: [Placed], size: CGSize) -> some View {
        // Profile chip: tap edits your profile; long press 2 s toggles demo mode.
        HStack(spacing: 8) {
            Text(app.initials.isEmpty ? "?" : app.initials).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 34, height: 34).background(Circle().fill(Ink.red))
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: 13, weight: .bold))
                Text(app.demo ? "DEMO MODE" : app.role).font(.system(size: 11)).opacity(0.8).lineLimit(1)
            }.foregroundStyle(.white).frame(maxWidth: 170, alignment: .leading)
        }
        .padding(5).padding(.trailing, 10).background(Capsule().fill(Ink.chip)).background(.ultraThinMaterial, in: Capsule())
        .onTapGesture { engine.stop(); editing = true }   // camera off so the photo retake can use it
        .onLongPressGesture(minimumDuration: 2) { app.demo.toggle(); UINotificationFeedbackGenerator().notificationOccurred(.success) }
        .offset(x: 14, y: 60)

        // Visible LIVE / DEMO switch (tap).
        Button { app.demo.toggle(); state.assign = [:]; state.pos = [:]; UISelectionFeedbackGenerator().selectionChanged() } label: {
            HStack(spacing: 6) {
                Circle().fill(app.demo ? Color.white.opacity(0.5) : Ink.red).frame(width: 8, height: 8)
                Text(app.demo ? "DEMO · TAP FOR LIVE" : "LIVE").font(Ink.bangers(14)).tracking(0.8).foregroundStyle(.white)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(Ink.chip))
        }
        .offset(x: 14, y: 108)

        // My photo: others recognise me by it.
        if !app.demo {
            Button { engine.stop(); takingPhoto = true } label: {
                Text(app.face == nil ? "📷 ADD PHOTO" : "📷 PHOTO ✓").font(Ink.bangers(14)).tracking(0.8).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(Capsule().fill(app.face == nil ? Ink.red : Ink.chip))
            }
            .offset(x: 100, y: 108)
        }

        // Nearby users not on a face yet.
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.locating, id: \.self) { t in
                Text("◎ " + t).font(Ink.bangers(13)).tracking(0.6).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Ink.chip))
            }
        }
        .offset(x: 14, y: 146)

        Button { app.showCaught = true } label: {
            Text("CAUGHT \(app.catches.count)").font(Ink.bangers(16)).tracking(0.8).foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 8).background(Capsule().fill(Ink.chip))
        }
        .frame(width: size.width - 14, alignment: .trailing).offset(y: 62)

        let nearby = app.demo ? placed.count + 2 : app.nearbyCount
        let issue = engine.note ?? (app.demo ? nil : app.bleIssue)
        ScanPill(text: issue ?? (placed.isEmpty ? "Scanning · \(nearby) nearby" : "\(placed.count) in view · \(nearby) nearby"))
            .onTapGesture { if engine.note != nil && engine.canAR { engine.resumeLive() } }
            .offset(x: 16, y: size.height - 34 - 34)
        if !app.demo && !app.bleDebug.isEmpty {
            Text(app.bleDebug).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Ink.chip))
                .offset(x: 16, y: size.height - 34 - 34 - 40)
        }

        Radar(blips: placed.map { p in (((p.head.x / size.width) - 0.5) * 70, p.scanning ? 0.6 : 0.45, !p.scanning) } + ghostBlips(placed))
            .offset(x: size.width - 16 - 108, y: size.height - 30 - 108)
    }

    private func ghostBlips(_ placed: [Placed]) -> [(Double, Double, Bool)] {
        if app.demo { return [(-150, 0.78, false), (128, 0.62, false)] }
        let shown = Set(placed.map(\.person.id))
        return app.visiblePeers.filter { !shown.contains($0.peer.person?.id ?? "-") }.map { k, v in
            // Bluetooth has no direction: a stable pseudo-bearing per person, distance from signal strength.
            let angle = Double(k.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff } % 360) - 180
            return (angle, min(0.92, max(0.2, (-v.rssi - 40) / 50)), false)
        }
    }
}

struct ScanPill: View {
    let text: String
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Ink.red).frame(width: 8, height: 8).opacity(pulse ? 0.35 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
            Text(text).font(Ink.bangers(15)).tracking(0.8).foregroundStyle(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(Capsule().fill(Ink.chip))
        .onAppear { pulse = true }
    }
}

struct Radar: View {
    /// (bearing degrees, distance 0..1, lit)
    let blips: [(Double, Double, Bool)]
    var body: some View {
        TimelineView(.animation) { t in
            let angle = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 * 360
            ZStack {
                Circle().fill(Ink.chip)
                Circle().stroke(Ink.red.opacity(0.6), lineWidth: 1.5)
                Circle().stroke(.white.opacity(0.15)).padding(18)
                Circle().stroke(.white.opacity(0.15)).padding(36)
                Circle().fill(AngularGradient(stops: [.init(color: .clear, location: 0), .init(color: .clear, location: 290.0 / 360),
                                                     .init(color: Ink.red.opacity(0.55), location: 1)], center: .center))
                    .mask(Circle()).rotationEffect(.degrees(angle))
                Circle().fill(.white).frame(width: 9, height: 9)
                ForEach(Array(blips.enumerated()), id: \.offset) { _, b in
                    let a = (b.0 - 90) * .pi / 180
                    Circle().fill(b.2 ? Ink.red : .white.opacity(0.45)).frame(width: 8, height: 8)
                        .scaleEffect(b.2 ? 1.35 : 1).shadow(color: b.2 ? Ink.red : .clear, radius: 4)
                        .offset(x: cos(a) * b.1 * 47.5, y: sin(a) * b.1 * 47.5)
                }
            }
        }
        .frame(width: 108, height: 108)
    }
}

struct BubbleView: View {
    let person: Person
    let scanning: Bool
    let tilt: Double
    let tailX: CGFloat
    let size: CGSize
    @State private var landed = false
    @State private var badge = false

    var body: some View {
        let anchor = UnitPoint(x: tailX / max(size.width, 1), y: 1)
        ZStack(alignment: .topLeading) {
            // Tail: 18pt square rotated 45°, half below the body.
            Rectangle().fill(.white).frame(width: 18, height: 18)
                .overlay(alignment: .bottomTrailing) { Rectangle().fill(Ink.ink).frame(width: 3, height: 18) }
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.ink).frame(height: 3) }
                .rotationEffect(.degrees(45))
                .offset(x: tailX - 9, y: size.height - 11)
            Group {
                if scanning {
                    ScanningDots().frame(width: size.width, height: size.height)
                } else {
                    Text(person.sentence).font(Ink.bangers(20)).tracking(0.7).lineSpacing(2)
                        .foregroundStyle(Ink.ink).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(EdgeInsets(top: 12, leading: 16, bottom: 13, trailing: 16))
                        .frame(width: size.width, height: size.height, alignment: .leading)
                }
            }
            .mangaPanel()
            if !scanning {
                MatchBadge(score: person.score)
                    .rotationEffect(.degrees(-tilt * 2))
                    .scaleEffect(badge ? 1 : 0.01).offset(x: 12, y: badge ? -12 : -6).opacity(badge ? 1 : 0)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .rotationEffect(.degrees(tilt), anchor: anchor)
        .scaleEffect(scanning || landed ? 1 : 1.35, anchor: anchor)
        .rotationEffect(.degrees(scanning || landed ? 0 : -3), anchor: anchor)
        .opacity(scanning || landed ? 1 : 0)
        .onChange(of: scanning, initial: true) { _, s in
            guard !s else { return }
            withAnimation(.timingCurve(0.2, 0.9, 0.3, 1.2, duration: 0.3)) { landed = true }
            withAnimation(.timingCurve(0.3, 1.8, 0.5, 1, duration: 0.5).delay(0.12)) { badge = true }
        }
    }
}

struct ScanningDots: View {
    var body: some View {
        TimelineView(.animation) { t in
            HStack(spacing: 6) {
                ForEach(0..<3) { i in
                    let phase = (t.date.timeIntervalSinceReferenceDate - Double(i) * 0.15).truncatingRemainder(dividingBy: 0.9) / 0.9
                    Circle().fill(Ink.ink).frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * sin(phase * .pi)).scaleEffect(0.7 + 0.3 * sin(phase * .pi))
                }
            }
        }
    }
}
