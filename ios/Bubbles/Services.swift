import SwiftUI
import CoreBluetooth
import ARKit

// MARK: - Supabase (PostgREST + Edge Functions over URLSession)

enum Backend {
    static let iso = ISO8601DateFormatter()

    static func request(_ path: String, method: String = "GET", body: Any? = nil, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: Config.supabaseURL + path) else { throw URLError(.badURL) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = 12
        r.setValue(Config.supabaseAnonKey, forHTTPHeaderField: "apikey")
        // Legacy anon keys are JWTs and also go as Bearer; new sb_publishable_ keys go in `apikey` only.
        if Config.supabaseAnonKey.hasPrefix("eyJ") { r.setValue("Bearer \(Config.supabaseAnonKey)", forHTTPHeaderField: "Authorization") }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { r.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let d: Data, resp: URLResponse
        do { (d, resp) = try await URLSession.shared.data(for: r) } catch { print("[NET] \(method) \(path.prefix(40)) failed: \(error.localizedDescription)"); throw error }
        if let h = resp as? HTTPURLResponse, h.statusCode >= 300 {
            print("[NET] \(method) \(path.prefix(40)) -> \(h.statusCode) \(String(decoding: d.prefix(200), as: UTF8.self))")
            throw URLError(.badServerResponse)
        }
        print("[NET] \(method) \(path.prefix(40)) ok")
        return d
    }
    static func function(_ name: String, _ body: [String: Any]) async throws -> [String: Any] {
        let d = try await request("/functions/v1/\(name)", method: "POST", body: body)
        return (try JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    /// Upserts profile by device id, replaces lines, bumps version. Returns profile id.
    static func saveProfile(device: String, name: String, lines: [ProfileLine]) async throws -> String {
        let existing = try await request("/rest/v1/profiles?device_id=eq.\(device)&select=id,version")
        let rows = (try JSONSerialization.jsonObject(with: existing) as? [[String: Any]]) ?? []
        let version = ((rows.first?["version"] as? Int) ?? 0) + 1
        let d = try await request("/rest/v1/profiles?on_conflict=device_id", method: "POST",
                                  body: ["device_id": device, "name": name, "version": version, "updated_at": iso.string(from: Date())],
                                  prefer: "resolution=merge-duplicates,return=representation")
        guard let id = (try JSONSerialization.jsonObject(with: d) as? [[String: Any]])?.first?["id"] as? String, !id.isEmpty else {
            throw URLError(.cannotParseResponse)
        }
        _ = try await request("/rest/v1/profile_lines?profile_id=eq.\(id)", method: "DELETE")
        let body: [[String: Any]] = lines.map {
            var l: [String: Any] = ["profile_id": id, "kind": $0.kind.rawValue, "text": $0.text, "source": $0.source]
            // Every row needs the same keys (PostgREST bulk insert), so send null when there's no expiry.
            l["expires_at"] = $0.expiresAt.map { iso.string(from: $0) as Any } ?? NSNull()
            return l
        }
        if !body.isEmpty { _ = try await request("/rest/v1/profile_lines", method: "POST", body: body) }
        return id
    }

    static func registerToken(_ token: String, profileID: String) async -> Bool {
        (try? await request("/rest/v1/ble_tokens", method: "POST",
                            body: ["token": token, "profile_id": profileID, "expires_at": iso.string(from: Date().addingTimeInterval(3600))])) != nil
    }

    static func match(viewer: String, token: String) async -> Person? {
        guard let j = try? await function("match", ["viewer_id": viewer, "token": token]), let id = j["target_id"] as? String else { return nil }
        let lines = (j["lines"] as? [[String: Any]] ?? []).compactMap { l -> ProfileLine? in
            guard let k = LineKind(rawValue: l["kind"] as? String ?? ""), let t = l["text"] as? String else { return nil }
            return ProfileLine(kind: k, text: t)
        }
        let sentence = (j["sentence"] as? String ?? "").oneSentence
        guard !sentence.isEmpty else { return nil }
        return Person(id: id, name: j["name"] as? String ?? "", sentence: sentence,
                      kind: LineKind(rawValue: j["kind"] as? String ?? "") ?? .identity, score: j["score"] as? Int ?? 50, lines: lines)
    }

    static func sendWave(from: String, to: String, sentence: String) async {
        _ = try? await request("/rest/v1/waves", method: "POST", body: ["from_id": from, "to_id": to, "sentence": sentence])
    }
    /// Unseen waves for me, marked seen. Returns (from name, sentence).
    static func takeWaves(me: String) async -> [(String, String)] {
        guard let d = try? await request("/rest/v1/waves?to_id=eq.\(me)&seen_at=is.null&select=id,from_id,sentence"),
              let rows = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]], !rows.isEmpty else { return [] }
        var out: [(String, String)] = []
        for w in rows {
            let id = w["id"] as? String ?? "", from = w["from_id"] as? String ?? ""
            _ = try? await request("/rest/v1/waves?id=eq.\(id)", method: "PATCH", body: ["seen_at": iso.string(from: Date())])
            let pd = try? await request("/rest/v1/profiles?id=eq.\(from)&select=name")
            let name = ((pd.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [[String: Any]])?.first?["name"] as? String) ?? "Someone"
            out.append((name, w["sentence"] as? String ?? ""))
        }
        return out
    }
    static func saveCatch(owner: String, p: Person) async {
        _ = try? await request("/rest/v1/catches", method: "POST",
                               body: ["owner_id": owner, "target_id": p.id, "sentence": p.sentence, "score": p.score, "rarity": p.rarity.rawValue],
                               prefer: "resolution=merge-duplicates")
    }
}

// MARK: - Bluetooth

/// Public profile carried over Bluetooth, so two phones work with no backend (and as a fallback when it is down).
struct Card: Codable, Equatable {
    struct Line: Codable, Equatable { var k: String; var t: String }
    var u: String      // stable app install id
    var n: String      // name
    var l: [Line]

    /// JSON that fits one long characteristic read (512 bytes). Asks and offers matter most for matching,
    /// so when it doesn't fit, extra "about" lines are dropped first.
    static func encode(uid: String, name: String, lines: [ProfileLine]) -> Data {
        let rank: [LineKind: Int] = [.ask: 0, .offer: 1, .looking_for: 2, .plan: 3, .identity: 4]
        let ordered = lines.enumerated().sorted { (rank[$0.element.kind] ?? 9, $0.offset) < (rank[$1.element.kind] ?? 9, $1.offset) }.map(\.element)
        var c = Card(u: uid, n: String(name.prefix(40)), l: ordered.map { Line(k: $0.kind.rawValue, t: String($0.text.prefix(90))) })
        while true {
            let d = (try? JSONEncoder().encode(c)) ?? Data()
            if d.count <= 512 || c.l.isEmpty { return d }
            c.l.removeLast()
        }
    }
}

struct Peer {
    var token: String?
    var card: Card?
    var rssi: Double
    var lastSeen: Date
    var person: Person?
    /// Their face signature (from their photo), read over Bluetooth.
    var face: [Float]?
    /// Same human across rotating Bluetooth addresses.
    func key(_ id: UUID) -> String { card.map { "u-" + $0.u } ?? person?.id ?? token ?? id.uuidString }
}

final class BLE: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let service = CBUUID(string: "67B45D74-F99F-4401-AF1A-6794602F3D08")
    static let tokenChar = CBUUID(string: "DB0A724D-9CD5-4E63-8212-F493554F8923")
    static let cardChar = CBUUID(string: "5C3A9E1B-2F4D-4B8A-9C61-7E2D0F8B4A13")
    /// Face signature: 512 bytes (int8 x 512), empty if the user took no photo.
    static let faceChar = CBUUID(string: "E1B2C3D4-5A6B-4C7D-8E9F-0A1B2C3D4E5F")

    var onPeer: (UUID, String, Data?, Data?) -> Void = { _, _, _, _ in }
    var onRSSI: (UUID, Double) -> Void = { _, _ in }
    var onState: (String?) -> Void = { _ in }
    private(set) var token = Data()
    var card = Data()
    var face = Data()
    private var pm: CBPeripheralManager!
    private var cm: CBCentralManager!
    private var scanning = false

    // Per remote peripheral read state.
    private var pending: [UUID: CBPeripheral] = [:]
    private struct Read { var left: Int; var token: String?; var card: Data?; var face: Data? }
    private var reads: [UUID: Read] = [:]
    private var known = Set<UUID>()
    private var failures: [UUID: Int] = [:]
    private var nextTry: [UUID: Date] = [:]

    // Diagnostics, shown on the scan screen in live mode.
    private(set) var advertising = false
    private(set) var advError: String?
    private(set) var heard = Set<UUID>()
    private(set) var readsOK = 0
    private(set) var readsFailed = 0
    var summary: String {
        let adv = advertising ? "on" : (advError.map { "ERR \($0)" } ?? "off")
        return "BT adv \(adv) · scan \(cm?.isScanning == true ? "on" : "off") · heard \(heard.count) · read \(readsOK)/\(readsOK + readsFailed)"
    }
    private func log(_ s: String) { print("[BLE] \(s)") }

    func start(token: Data, card: Data) {
        self.token = token; self.card = card
        if pm == nil {
            pm = CBPeripheralManager(delegate: self, queue: .main)
            cm = CBCentralManager(delegate: self, queue: .main)
        }
    }
    func rotate(_ t: Data) { token = t }
    func setScanning(_ on: Bool) { scanning = on; applyScan() }
    /// Re-read every peer, to pick up rotated tokens and edited cards.
    func forgetAll() { known.removeAll() }
    func retrySoon(_ id: UUID) { known.remove(id); nextTry[id] = Date().addingTimeInterval(3) }

    private func applyScan() {
        guard let cm, cm.state == .poweredOn else { return }
        if scanning { cm.scanForPeripherals(withServices: [Self.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        else { cm.stopScan() }
    }
    private func report(_ s: CBManagerState) {
        switch s {
        case .poweredOff: onState("Bluetooth is off")
        case .unauthorized: onState("Allow Bluetooth: Settings > Bubbles")
        case .unsupported: onState("No Bluetooth LE on this device")
        case .poweredOn: onState(nil)
        default: break
        }
    }

    // Peripheral: advertise service, serve token, card and face on read (long reads use offsets).
    func peripheralManagerDidUpdateState(_ p: CBPeripheralManager) {
        report(p.state)
        guard p.state == .poweredOn else { return }
        let t = CBMutableCharacteristic(type: Self.tokenChar, properties: .read, value: nil, permissions: .readable)
        let c = CBMutableCharacteristic(type: Self.cardChar, properties: .read, value: nil, permissions: .readable)
        let f = CBMutableCharacteristic(type: Self.faceChar, properties: .read, value: nil, permissions: .readable)
        let s = CBMutableService(type: Self.service, primary: true); s.characteristics = [t, c, f]
        p.stopAdvertising(); p.removeAllServices(); p.add(s)
    }
    func peripheralManager(_ p: CBPeripheralManager, didAdd s: CBService, error: Error?) {
        if let error { advError = error.localizedDescription; log("add service failed: \(error)"); return }
        p.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service]])
    }
    func peripheralManagerDidStartAdvertising(_ p: CBPeripheralManager, error: Error?) {
        advertising = error == nil; advError = error?.localizedDescription
        log(error.map { "advertise failed: \($0)" } ?? "advertising")
    }
    func peripheralManager(_ p: CBPeripheralManager, didReceiveRead req: CBATTRequest) {
        let value = req.characteristic.uuid == Self.cardChar ? card
            : req.characteristic.uuid == Self.faceChar ? face : token
        guard req.offset <= value.count else { return p.respond(to: req, withResult: .invalidOffset) }
        req.value = value.subdata(in: req.offset..<value.count)
        p.respond(to: req, withResult: .success)
    }

    // Central: scan, connect once per peripheral, read token + card + face, disconnect; RSSI keeps flowing from adverts.
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        report(c.state)
        log("central state \(c.state.rawValue)")
        if c.state != .poweredOn { pending.removeAll(); reads.removeAll() }
        applyScan()
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) {
        let r = rssi.doubleValue
        guard r < 0, r > -110 else { return }   // 127 = unavailable
        onRSSI(p.identifier, r)
        let id = p.identifier
        if heard.insert(id).inserted { log("heard \(id) rssi \(Int(r))") }
        guard !known.contains(id), pending[id] == nil, (nextTry[id] ?? .distantPast) < Date() else { return }
        pending[id] = p; p.delegate = self; c.connect(p)
        // CoreBluetooth never times out a connect; do it ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            if self?.pending[id] === p { self?.done(p) }
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) { p.discoverServices([Self.service]) }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) { done(p) }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if pending[p.identifier] != nil { done(p) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = p.services?.first(where: { $0.uuid == Self.service }) else { return done(p) }
        p.discoverCharacteristics([Self.tokenChar, Self.cardChar, Self.faceChar], for: s)
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        let chars = (s.characteristics ?? []).filter { [Self.tokenChar, Self.cardChar, Self.faceChar].contains($0.uuid) }
        guard chars.contains(where: { $0.uuid == Self.tokenChar }) else { return done(p) }
        reads[p.identifier] = Read(left: chars.count)
        chars.forEach { p.readValue(for: $0) }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard var r = reads[p.identifier] else { return }
        if error == nil, let v = ch.value {
            if ch.uuid == Self.tokenChar, v.count == 16 { r.token = v.map { String(format: "%02x", $0) }.joined() }
            if ch.uuid == Self.cardChar, !v.isEmpty { r.card = v }
            if ch.uuid == Self.faceChar, !v.isEmpty { r.face = v }
        }
        r.left -= 1
        reads[p.identifier] = r
        guard r.left <= 0 else { return }
        log("reads done: card \(r.card?.count ?? 0)B, face \(r.face?.count ?? 0)B")
        done(p)
    }

    private func done(_ p: CBPeripheral) {
        let id = p.identifier
        guard pending[id] != nil else { return }
        let r = reads[id]
        pending[id] = nil; reads[id] = nil
        cm.cancelPeripheralConnection(p)
        if let tok = r?.token {
            readsOK += 1; log("read ok \(id) card \(r?.card?.count ?? 0)B")
            known.insert(id); failures[id] = nil
            onPeer(id, tok, r?.card, r?.face)
        } else {
            // Back off: 2, 4, 8 … 30 s, so a flaky phone does not hog the radio.
            readsFailed += 1; log("read failed \(id)")
            let f = (failures[id] ?? 0) + 1
            failures[id] = f
            nextTry[id] = Date().addingTimeInterval(min(30, pow(2, Double(f))))
        }
    }
}

// MARK: - Offline matching (used when there is no backend, or it fails)

enum LocalMatch {
    private static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "have", "from", "your", "about", "into", "what",
                                            "want", "need", "help", "anyone", "someone", "working", "would", "like", "love", "just",
                                            "really", "looking", "know", "some", "more", "them", "they", "will", "here"]
    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 3 && !stop.contains($0) })
    }
    static func person(_ c: Card, viewer: [ProfileLine]) -> Person {
        let mine = viewer.reduce(into: Set<String>()) { $0.formUnion(words($1.text)) }
        let myKinds = Set(viewer.map(\.kind))
        let base: [LineKind: Int] = [.identity: 10, .offer: 12, .ask: 12, .looking_for: 14, .plan: 6]
        let lines = c.l.compactMap { l in LineKind(rawValue: l.k).map { ProfileLine(kind: $0, text: l.t) } }.filter { !$0.text.isEmpty }
        var best: (line: ProfileLine, score: Int)?
        for l in lines {
            var s = base[l.kind] ?? 0
            if l.kind == .offer && myKinds.contains(.ask) { s += 18 }
            if l.kind == .ask && myKinds.contains(.offer) { s += 18 }
            s += min(40, 10 * words(l.text).intersection(mine).count)
            if best == nil || s > best!.score { best = (l, s) }
        }
        let name = c.n.isEmpty ? "Someone" : c.n
        let pick = best?.line ?? ProfileLine(kind: .identity, text: "Hi, I'm \(name).")
        return Person(id: "local-\(c.u)", name: name, sentence: pick.text.oneSentence, kind: pick.kind,
                      score: min(95, 50 + (best?.score ?? 0)), lines: lines)
    }
}

// MARK: - App state

/// Someone who can get a bubble: one per human. `face` is their photo signature, if they shared one.
struct Pinnable { let key: String; let person: Person; let rssi: Double; let face: [Float]? }

@Observable final class AppModel {
    var name = ""
    var lines: [ProfileLine] = []
    var profileID = ""
    var onboarded = false
    /// Demo people instead of real phones. Remembered across launches; real phones start live.
    var demo = false { didSet { UserDefaults.standard.set(demo, forKey: "demo") } }
    var bleDebug = ""
    var peers: [UUID: Peer] = [:]
    var catches: [Catch] = []
    var toast: String?
    var selected: Person?
    var showCaught = false
    var bleIssue: String?
    /// My face signature from my photo (nil = no photo yet). Shared over Bluetooth so others recognise me.
    var face: [Float]?

    @ObservationIgnored let ble = BLE()
    @ObservationIgnored let uid: String
    @ObservationIgnored private var tokenHex = ""
    @ObservationIgnored private var tokenRegistered = false
    @ObservationIgnored private var profileDirty = false
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var profileRev = 0     // bumps on every local edit
    @ObservationIgnored private var matchTries: [UUID: Int] = [:]
    @ObservationIgnored private var loops: [Task<Void, Never>] = []

    init() {
        let d = UserDefaults.standard
        if let u = d.string(forKey: "uid") { uid = u } else { uid = UUID().uuidString; d.set(uid, forKey: "uid") }
        name = d.string(forKey: "name") ?? ""
        profileID = d.string(forKey: "profileID") ?? ""
        onboarded = d.bool(forKey: "onboarded")
        profileDirty = d.bool(forKey: "profileDirty")
        demo = d.object(forKey: "demo") as? Bool ?? !ARWorldTrackingConfiguration.isSupported
        if let data = d.data(forKey: "lines"), let l = try? JSONDecoder().decode([ProfileLine].self, from: data) { lines = l }
        face = d.data(forKey: "face").flatMap(FaceID.unpack)
        if let data = d.data(forKey: "catches"), let c = try? JSONDecoder().decode([Catch].self, from: data) { catches = c }
        if onboarded && lines.isEmpty { lines = [ProfileLine(kind: .identity, text: "Hi, I'm \(name).")] }
        if onboarded { startServices() }
    }

    var role: String { lines.first(where: { $0.kind == .identity })?.text ?? lines.first?.text ?? "Bubbles" }
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased() }
    private var publicLines: [ProfileLine] { lines.filter { ($0.expiresAt ?? .distantFuture) > Date() } }

    /// Phones heard in the last 10 s above -85 dBm, one entry per human (Bluetooth addresses rotate).
    var visiblePeers: [(key: String, peer: Peer)] {
        let now = Date()
        var best: [String: Peer] = [:]
        for (id, p) in peers where p.rssi > -85 && now.timeIntervalSince(p.lastSeen) < 10 {
            let k = p.key(id)
            if let b = best[k] {
                var keep = b.lastSeen > p.lastSeen ? b : p
                keep.person = keep.person ?? b.person ?? p.person   // prefer one that has a match
                keep.face = keep.face ?? b.face ?? p.face
                if b.person?.id.hasPrefix("local-") == false { keep.person = b.person }
                if p.person?.id.hasPrefix("local-") == false { keep.person = p.person }
                best[k] = keep
            } else { best[k] = p }
        }
        return best.map { ($0.key, $0.value) }
    }
    /// Peers with a match result, strongest signal first.
    var matchedPeers: [Pinnable] {
        visiblePeers.compactMap { k, p in p.person.map { Pinnable(key: k, person: $0, rssi: p.rssi, face: p.face) } }
            .sorted { $0.rssi > $1.rssi }
    }
    var nearbyCount: Int { visiblePeers.count }

    func setFace(_ f: [Float]?) {
        face = f
        persist()
        ble.face = f.map(FaceID.pack) ?? Data()
        show(f == nil ? "Photo removed" : "Photo saved: nearby phones will find your face")
    }

    /// Edited profile: saved locally, served on Bluetooth right away, synced to Supabase in the background.
    func updateProfile(name: String, lines: [ProfileLine]) {
        self.name = name
        self.lines = lines.map { var l = $0; l.text = l.text.oneSentence; return l }.filter { !$0.text.isEmpty }
        if self.lines.isEmpty { self.lines = [ProfileLine(kind: .identity, text: "Hi, I'm \(name).")] }
        profileDirty = true; profileRev += 1
        persist()
        ble.card = Card.encode(uid: uid, name: name, lines: publicLines)
        syncProfile()
        show("Profile saved")
    }

    func finishOnboarding(name: String, lines: [ProfileLine]) {
        self.name = name
        self.lines = lines.map { var l = $0; l.text = l.text.oneSentence; return l }.filter { !$0.text.isEmpty }
        onboarded = true
        profileDirty = true; profileRev += 1
        persist()
        startServices()     // never wait on the network here; sync happens in the background
    }

    func persist() {
        let d = UserDefaults.standard
        d.set(name, forKey: "name"); d.set(profileID, forKey: "profileID"); d.set(onboarded, forKey: "onboarded")
        d.set(profileDirty, forKey: "profileDirty")
        d.set(try? JSONEncoder().encode(lines), forKey: "lines")
        d.set(try? JSONEncoder().encode(catches), forKey: "catches")
        d.set(face.map(FaceID.pack), forKey: "face")
    }

    func startServices() {
        guard loops.isEmpty else { return }
        ble.onRSSI = { [weak self] id, r in
            guard let self else { return }
            var p = self.peers[id] ?? Peer(rssi: r, lastSeen: Date())
            // Restart the average after a gap so an old value does not drag it.
            p.rssi = Date().timeIntervalSince(p.lastSeen) > 5 ? r : p.rssi * 0.7 + r * 0.3
            p.lastSeen = Date()
            self.peers[id] = p
        }
        ble.onPeer = { [weak self] id, tok, cardData, faceData in
            guard let self else { return }
            var p = self.peers[id] ?? Peer(rssi: -70, lastSeen: Date())
            p.token = tok
            if let f = faceData.flatMap(FaceID.unpack) { p.face = f }
            if let cardData, let c = try? JSONDecoder().decode(Card.self, from: cardData) {
                p.card = c
                if p.person == nil || p.person!.id.hasPrefix("local-") { p.person = LocalMatch.person(c, viewer: self.publicLines) }
            }
            self.peers[id] = p
            self.matchTries[id] = 0
            self.resolve(id)
        }
        ble.onState = { [weak self] s in self?.bleIssue = s }
        tokenHex = Self.newToken()
        ble.face = face.map(FaceID.pack) ?? Data()
        ble.start(token: Data(hexString: tokenHex), card: Card.encode(uid: uid, name: name, lines: publicLines))
        syncProfile()
        registerToken()
        loops.append(Task { @MainActor [weak self] in
            // Rotate every 30 min (tokens live 1 h on the server), then re-read peers to get their new tokens.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1800))
                guard let self else { return }
                self.tokenHex = Self.newToken(); self.tokenRegistered = false
                self.ble.rotate(Data(hexString: self.tokenHex)); self.registerToken()
                self.ble.forgetAll()
            }
        })
        loops.append(Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                guard let self else { return }
                await self.pollWaves()
                self.bleDebug = self.ble.summary
                // Re-read cards every minute so new selfies and profile edits reach other phones.
                tick += 1
                if tick % 15 == 0 { self.ble.forgetAll() }
                // Housekeeping: drop peers unseen for 2 min; retry backend work that failed.
                self.peers = self.peers.filter { Date().timeIntervalSince($0.value.lastSeen) < 120 }
                if self.profileDirty || self.profileID.isEmpty { self.syncProfile() }
                if !self.tokenRegistered { self.registerToken() }
            }
        })
    }

    private static func newToken() -> String { (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined() }

    /// Push the profile to Supabase until it succeeds. Bluetooth works without it.
    private func syncProfile() {
        guard Config.online, !syncing, profileDirty || profileID.isEmpty else { return }
        syncing = true
        let name = name, lines = lines, device = uid, rev = profileRev
        Task { @MainActor in
            defer { syncing = false }
            guard let id = try? await Backend.saveProfile(device: device, name: name, lines: lines) else { return }
            profileID = id
            // Edited again while uploading: stay dirty so the 4 s loop uploads the newer version.
            if rev == profileRev { profileDirty = false } else { DispatchQueue.main.async { self.syncProfile() } }
            persist()
            tokenRegistered = false; registerToken()
            for pid in peers.keys { matchTries[pid] = 0; resolve(pid) }
        }
    }

    private func registerToken() {
        guard Config.online, !profileID.isEmpty, !tokenRegistered else { return }
        let t = tokenHex, id = profileID
        Task { @MainActor in if await Backend.registerToken(t, profileID: id), t == tokenHex { tokenRegistered = true } }
    }

    /// Ask the backend for the best line. Retries: the other phone may not have registered its token yet.
    private func resolve(_ id: UUID) {
        guard Config.online, !profileID.isEmpty, let tok = peers[id]?.token else { return }
        let me = profileID
        Task { @MainActor in
            if let person = await Backend.match(viewer: me, token: tok) {
                peers[id]?.person = person
            } else {
                let n = (matchTries[id] ?? 0) + 1
                matchTries[id] = n
                guard n < 6 else { return }   // keep the Bluetooth card result
                try? await Task.sleep(for: .seconds(Double(n) * 3))
                if peers[id]?.token == tok { resolve(id) }
            }
        }
    }

    private func pollWaves() async {
        guard Config.online, !profileID.isEmpty else { return }
        for (from, s) in await Backend.takeWaves(me: profileID) { show("\(from) waved: \(s)") }
    }

    func show(_ text: String) {
        withAnimation(.spring) { toast = text }
        Task { @MainActor in try? await Task.sleep(for: .seconds(3.5)); if toast == text { withAnimation { toast = nil } } }
    }

    private func isRemote(_ p: Person) -> Bool { Config.online && !profileID.isEmpty && !p.id.hasPrefix("demo") && !p.id.hasPrefix("local-") }

    func wave(_ p: Person) {
        let mine = lines.first?.text ?? "Hi!"
        if isRemote(p) { let me = profileID; Task { await Backend.sendWave(from: me, to: p.id, sentence: mine) } }
        show("You waved at \(p.name)")
    }

    func catchPerson(_ p: Person) {
        if !catches.contains(where: { $0.id == p.id }) { catches.insert(Catch(person: p, date: Date()), at: 0) }
        persist()
        if isRemote(p) { let me = profileID; Task { await Backend.saveCatch(owner: me, p: p) } }
        show("Caught \(p.name)! \(p.rarity.rawValue)")
    }
}

extension String {
    /// First sentence only, at most ~90 characters. One sentence per bubble, always.
    var oneSentence: String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        var out = t
        if let r = t.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            out = String(t[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
        }
        if out.count > 90 {
            let cut = out.prefix(88)
            out = (cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? String(cut)) + "…"
        }
        return out
    }
}

extension Data {
    init(hexString: String) {
        var d = Data(); var i = hexString.startIndex
        while i < hexString.endIndex, let j = hexString.index(i, offsetBy: 2, limitedBy: hexString.endIndex) {
            if let b = UInt8(hexString[i..<j], radix: 16) { d.append(b) }; i = j
        }
        self = d
    }
}
