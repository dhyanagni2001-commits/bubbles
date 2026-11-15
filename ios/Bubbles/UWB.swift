import Foundation
import NearbyInteraction
import ARKit
import simd

/// Ultra Wideband ranging to nearby Bubbles phones (NearbyInteraction).
///
/// Handshake rides on the existing Bluetooth connection: the phone with the smaller install id writes
/// `[uid length][uid][its token]` to the other phone's NI characteristic, then reads back that phone's
/// token for it. One NISession per peer. With camera assistance (iPhone 14+ needs it for direction)
/// the session shares our ARSession and reports each phone's position in AR world space.
final class UWB: NSObject, NISessionDelegate {
    struct Fix { var distance: Float?; var world: simd_float4x4?; var direction: simd_float3?; var at: Date }

    static var supported: Bool { NISession.deviceCapabilities.supportsPreciseDistanceMeasurement }
    static var cameraAssist: Bool { NISession.deviceCapabilities.supportsCameraAssistance }

    /// Set before scanning so new sessions can use camera assistance.
    var arSession: ARSession?
    private(set) var fixes: [String: Fix] = [:]               // peer uid -> latest fix
    private var sessions: [String: NISession] = [:]           // peer uid -> session
    private var configs: [String: NINearbyPeerConfiguration] = [:]
    private var owner: [ObjectIdentifier: String] = [:]       // session -> peer uid
    private var replies: [UUID: Data] = [:]                   // central id -> my token for it (responder side)

    /// Fresh fix (seen in the last 2 s) for a peer.
    func fix(_ uid: String) -> Fix? { fixes[uid].flatMap { Date().timeIntervalSince($0.at) < 2 ? $0 : nil } }
    var summary: String {
        guard Self.supported else { return "UWB n/a" }
        if let problem { return problem }
        let live = fixes.values.filter { Date().timeIntervalSince($0.at) < 2 }
        return "UWB \(sessions.count) sess · \(live.count) live · \(live.filter { $0.world != nil }.count) dir"
    }

    /// Initiator: should we start a handshake with this peer? Only the smaller uid initiates, and only
    /// when there is no session yet or it has not produced a position.
    func wantsHandshake(myUID: String, peerUID: String) -> Bool {
        guard Self.supported, myUID < peerUID else { return false }
        // Retry (each card re-read, ~1 min) while camera assistance has not produced a position yet.
        return sessions[peerUID] == nil || (Self.cameraAssist && arSession != nil && fix(peerUID)?.world == nil)
    }

    /// Initiator step 1: payload to write to the peer.
    func offer(myUID: String, peerUID: String) -> Data? {
        guard let tok = newSession(for: peerUID) else { return nil }
        return Self.pack(uid: myUID, token: tok)
    }
    /// Initiator step 2: the peer's token for us arrived; start ranging.
    func accept(peerUID: String, reply: Data) {
        guard let s = sessions[peerUID], let raw = try? (reply as NSData).decompressed(using: .zlib) as Data else { return }
        run(s, uid: peerUID, peerToken: raw)
    }

    /// Responder: a peer wrote its offer. Start a session for it and remember our token for its read.
    func handleOffer(_ data: Data, from central: UUID) {
        print("[UWB] offer received \(data.count)B")
        guard Self.supported, let (uid, token) = Self.unpack(data) else { print("[UWB] bad offer"); return }
        guard let mine = newSession(for: uid), let s = sessions[uid] else { return }
        replies[central] = (try? (mine as NSData).compressed(using: .zlib) as Data) ?? Data()
        run(s, uid: uid, peerToken: token)
    }
    func reply(for central: UUID) -> Data { replies[central] ?? Data() }

    // MARK: Sessions

    /// Why UWB cannot run, for the scan screen. Nil when fine.
    private(set) var problem: String?

    private func newSession(for uid: String) -> Data? {
        if let old = sessions[uid] { old.invalidate(); owner[ObjectIdentifier(old)] = nil; sessions[uid] = nil }
        // Try with camera assistance first, then without (distance only) if iOS gives no token.
        for withCamera in [true, false] where withCamera == false || (Self.cameraAssist && arSession != nil && !cameraRejected) {
            let s = NISession()
            s.delegate = self
            s.delegateQueue = .main
            // Read the token before attaching the ARSession: attaching first leaves discoveryToken nil.
            guard let tok = s.discoveryToken,
                  let d = try? NSKeyedArchiver.archivedData(withRootObject: tok, requiringSecureCoding: true) else {
                print("[UWB] no discovery token (camera \(withCamera))")
                s.invalidate()
                continue
            }
            if withCamera, let ar = arSession {
                s.setARSession(ar)
                print("[UWB] token \(d.count)B, ARSession attached")
            }
            if !withCamera { print("[UWB] token only without camera assistance: distance, no direction") }
            sessions[uid] = s; owner[ObjectIdentifier(s)] = uid; fixes[uid] = nil; cameraFor[uid] = withCamera
            problem = nil
            return d
        }
        problem = "UWB blocked: Settings > Privacy > Nearby Interactions > Bubbles ON"
        return nil
    }
    private var cameraFor: [String: Bool] = [:]
    /// iOS refused our ARSession for camera assistance; stop asking so distance-only ranging keeps working.
    private var cameraRejected = false

    private func run(_ s: NISession, uid: String, peerToken: Data) {
        guard let t = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NIDiscoveryToken.self, from: peerToken) else { return }
        let c = NINearbyPeerConfiguration(peerToken: t)
        if Self.cameraAssist && arSession != nil && cameraFor[uid] == true && !cameraRejected { c.isCameraAssistanceEnabled = true }
        configs[uid] = c
        s.run(c)
        print("[UWB] running with \(uid.prefix(8)) camera=\(c.isCameraAssistanceEnabled)")
    }

    private func drop(_ s: NISession) {
        guard let uid = owner[ObjectIdentifier(s)] else { return }
        s.invalidate()
        owner[ObjectIdentifier(s)] = nil; sessions[uid] = nil; configs[uid] = nil; fixes[uid] = nil
    }

    // MARK: NISessionDelegate

    func session(_ s: NISession, didUpdate objects: [NINearbyObject]) {
        guard let uid = owner[ObjectIdentifier(s)], let o = objects.first else { return }
        var f = fixes[uid] ?? Fix(at: Date())
        f.distance = o.distance ?? f.distance
        f.direction = o.direction ?? f.direction
        if let w = s.worldTransform(for: o) { f.world = w }
        f.at = Date()
        fixes[uid] = f
    }
    func session(_ s: NISession, didRemove objects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        // Peer closed the app or walked away: forget it so the next Bluetooth read can handshake again.
        drop(s)
    }
    func sessionWasSuspended(_ s: NISession) {}
    func sessionSuspensionEnded(_ s: NISession) {
        if let uid = owner[ObjectIdentifier(s)], let c = configs[uid] { s.run(c) }
    }
    func session(_ s: NISession, didInvalidateWith error: Error) {
        let code = (error as? NIError)?.code
        print("[UWB] invalidated: \(error.localizedDescription) code \(code.map { "\($0.rawValue)" } ?? "?")")
        if code == .userDidNotAllow { problem = "UWB blocked: Settings > Privacy > Nearby Interactions > Bubbles ON" }
        else if code == .invalidARConfiguration { cameraRejected = true; problem = "UWB: camera setup rejected, distance only" }
        drop(s)
    }

    // MARK: Wire format (tokens compressed: keyed archives are mostly repeated class names)

    private static func pack(uid: String, token: Data) -> Data? {
        guard let z = try? (token as NSData).compressed(using: .zlib) as Data else { return nil }
        let u = Data(uid.utf8)
        guard u.count < 256 else { return nil }
        let d = Data([UInt8(u.count)]) + u + z
        return d.count <= 512 ? d : nil
    }
    private static func unpack(_ d: Data) -> (String, Data)? {
        let b = [UInt8](d)
        guard let n = b.first, b.count > 1 + Int(n),
              let uid = String(bytes: b[1...Int(n)], encoding: .utf8),
              let tok = try? (Data(b[(1 + Int(n))...]) as NSData).decompressed(using: .zlib) as Data else { return nil }
        return (uid, tok)
    }
}
