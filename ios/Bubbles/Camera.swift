import SwiftUI
import ARKit
import AVFoundation
import MediaPipeTasksVision

/// A tracked head in normalized, upright, top-left image coordinates.
struct HeadTrack: Identifiable, Equatable {
    let id: Int
    var x: CGFloat, y: CGFloat, size: CGFloat
    var born: Date
    /// Running average of this face's signature (live mode), for recognising who it is.
    var sig: [Float]? = nil
}

/// Nearest-neighbour head tracker (port of tools/tracks.py).
final class HeadTracker {
    private struct T { let id: Int; var hist: [CGPoint3]; var missed: Int; let born: Date; var sig: [Float]? = nil }
    struct CGPoint3 { var x, y, s: CGFloat }
    private var tracks: [T] = []
    private var nextID = 0

    func update(faces: [CGRect], sigs: [[Float]?] = []) -> [HeadTrack] {
        let cands = faces.map { CGPoint3(x: $0.midX, y: $0.minY - $0.height * 0.25, s: $0.width) }
        var used = Set<Int>()
        for (ci, c) in cands.enumerated() {
            let sig = ci < sigs.count ? sigs[ci] : nil
            var best: Int? = nil, bd: CGFloat = 0.09
            for (i, t) in tracks.enumerated() where !used.contains(t.id) {
                let l = t.hist.last!
                let d = hypot(c.x - l.x, (c.y - l.y) * 1.78)
                if d < bd { bd = d; best = i }
            }
            if let i = best {
                tracks[i].hist.append(c); tracks[i].hist = Array(tracks[i].hist.suffix(5)); tracks[i].missed = 0
                if let sig {
                    if let old = tracks[i].sig { tracks[i].sig = FaceID.normalized(zip(old, sig).map { $0 * 0.6 + $1 * 0.4 }) }
                    else { tracks[i].sig = sig }
                }
                used.insert(tracks[i].id)
            } else {
                tracks.append(T(id: nextID, hist: [c], missed: 0, born: Date(), sig: sig)); used.insert(nextID); nextID += 1
            }
        }
        for i in tracks.indices where !used.contains(tracks[i].id) { tracks[i].missed += 1 }
        tracks.removeAll { $0.missed > 8 }
        return tracks.filter { $0.hist.count >= 2 }.map { t in
            let n = CGFloat(t.hist.count)
            return HeadTrack(id: t.id, x: t.hist.map(\.x).reduce(0, +) / n, y: t.hist.map(\.y).reduce(0, +) / n,
                             size: t.hist.map(\.s).reduce(0, +) / n, born: t.born, sig: t.sig)
        }
    }
}

/// Runs MediaPipe face detection on frames from ARKit (device) or the bundled clip (simulator / fallback).
@Observable final class HeadEngine: NSObject, ARSessionDelegate {
    var heads: [HeadTrack] = []
    /// Face detection on/off.
    @ObservationIgnored var detectHeads = true
    /// Compute face signatures (live mode) so faces can be matched to nearby users' photos.
    @ObservationIgnored var recognize = false
    var imageSize = CGSize(width: 720, height: 1280)   // upright image size, for aspect-fill mapping
    var useAR = ARWorldTrackingConfiguration.isSupported
    /// The device can do live AR; useAR may be off temporarily after a failure.
    let canAR = ARWorldTrackingConfiguration.isSupported
    @ObservationIgnored let session = ARSession()
    @ObservationIgnored private let tracker = HeadTracker()
    @ObservationIgnored private let queue = DispatchQueue(label: "vision")
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var frameCount = 0
    var player: AVPlayer?
    /// Why the live camera is not in use, shown in the scan pill.
    var note: String?
    @ObservationIgnored private var output: AVPlayerItemVideoOutput?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loopObserver: NSObjectProtocol?
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var lastFailure = Date.distantPast
    @ObservationIgnored private var denied = false

    func start() {
        if canAR && !denied {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .denied, .restricted: denied = true; return fallback("Camera is off: Settings > Bubbles > Camera")
            default: break   // .notDetermined: ARKit asks; a refusal arrives as didFailWithError
            }
            runLive()
        } else {
            startClip()
        }
    }

    private func runLive() {
        timer?.invalidate(); timer = nil; player?.pause()
        useAR = true; note = nil; heads = []
        session.delegate = self
        session.run(Self.arConfig())
    }

    /// Rear-camera world tracking, gravity aligned.
    static func arConfig() -> ARWorldTrackingConfiguration {
        let c = ARWorldTrackingConfiguration()
        c.worldAlignment = .gravity
        return c
    }


    /// Take the camera back: live AR again if the device can, even after an earlier fallback.
    func resumeLive() {
        failures = 0
        if canAR && !denied && AVCaptureDevice.authorizationStatus(for: .video) != .denied { runLive() } else { start() }
    }

    /// Live camera unavailable: keep the show going on the bundled clip.
    private func fallback(_ why: String) {
        note = why
        session.pause()
        heads = []
        useAR = false
        startClip()
    }

    private func startClip() {
        timer?.invalidate()
        if let player { player.play() } else {
            guard let url = Bundle.main.url(forResource: "feed", withExtension: "mp4") else { return }
            let item = AVPlayerItem(url: url)
            let out = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            item.add(out); output = out
            let p = AVPlayer(playerItem: item); p.isMuted = true
            loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
                p.seek(to: .zero); p.play()
            }
            player = p; p.play()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 15, repeats: true) { [weak self] _ in self?.pullVideo() }
    }

    func stop() { session.pause(); timer?.invalidate(); timer = nil; player?.pause() }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        let isDenied = (error as? ARError)?.code == .cameraUnauthorized
        DispatchQueue.main.async { [self] in
            if isDenied { denied = true; return fallback("Camera is off: Settings > Bubbles > Camera") }
            // Usually transient (camera briefly busy). Retry; fall back to the clip only after 3 quick failures.
            failures = Date().timeIntervalSince(lastFailure) < 10 ? failures + 1 : 1
            lastFailure = Date()
            print("[CAM] AR failed (\(failures)): \(error.localizedDescription)")
            if failures >= 3 { return fallback("Camera unavailable, showing demo clip. Tap here to retry.") }
            note = "Camera restarting…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in if useAR { runLive() } }
        }
    }
    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { [self] in heads = [] }
    }
    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        // Camera came back (call ended, selfie closed): restart cleanly.
        DispatchQueue.main.async { [self] in if useAR { runLive() } }
    }

    private func pullVideo() {
        guard let out = output else { return }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard let buf = out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        detect(buf, orientation: .up, size: CGSize(width: CVPixelBufferGetWidth(buf), height: CVPixelBufferGetHeight(buf)))
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let buf = frame.capturedImage
        DispatchQueue.main.async { [self] in
            frameCount += 1
            guard frameCount % 2 == 0 else { return }   // ~15 Hz
            // Portrait: capturedImage is landscape, rotate .right.
            detect(buf, orientation: .right, size: CGSize(width: CVPixelBufferGetHeight(buf), height: CVPixelBufferGetWidth(buf)))
        }
    }

    // MARK: Face detection (MediaPipe BlazeFace) and signatures (FaceNet, live mode only).

    @ObservationIgnored private var detector: FaceDetector?
    @ObservationIgnored private var detectorFailed = false
    @ObservationIgnored private var lastCount = -1

    private func makeDetector() -> FaceDetector? {
        guard let path = Bundle.main.path(forResource: "blaze_face_short_range", ofType: "tflite") else {
            print("[MP] model missing"); return nil
        }
        let o = FaceDetectorOptions()
        o.baseOptions.modelAssetPath = path
        o.runningMode = .image
        o.minDetectionConfidence = 0.45
        do { return try FaceDetector(options: o) } catch { print("[MP] detector failed: \(error)"); return nil }
    }

    @ObservationIgnored private let renderer = Renderer()

    /// BlazeFace sees a 128 px square, so faces across a room vanish in the full frame. Detect on overlapping
    /// square tiles (each scaled up) and merge. Returns faces normalized to the upright frame, top-left origin.
    private func detectTiled(_ detector: FaceDetector, _ img: CIImage) -> [CGRect] {
        let W = img.extent.width, H = img.extent.height
        var tiles: [CGRect] = []
        for side in [W, W * 0.55] {
            let step = side * 0.5
            var y: CGFloat = 0
            while true {
                var x: CGFloat = 0
                while true { tiles.append(CGRect(x: min(x, W - side), y: min(y, H - side), width: side, height: side)); if x + side >= W { break }; x += step }
                if y + side >= H { break }; y += step
            }
        }
        var found: [(CGRect, Float)] = []
        for tile in tiles {
            guard let px = renderer.square(img, crop: tile, side: 256), let mp = try? MPImage(pixelBuffer: px, orientation: .up),
                  let r = try? detector.detect(image: mp) else { continue }
            for d in r.detections {
                let b = d.boundingBox, k = tile.width / 256
                // MediaPipe box: pixels, top-left origin. CIImage tile: bottom-left origin.
                let x = tile.minX + b.minX * k
                let yTop = (H - tile.maxY) + b.minY * k
                found.append((CGRect(x: x / W, y: yTop / H, width: b.width * k / W, height: b.height * k / H), d.categories.first?.score ?? 0))
            }
        }
        var keep: [CGRect] = []
        for (r, _) in found.sorted(by: { $0.1 > $1.1 }) {
            if !keep.contains(where: { k in let i = k.intersection(r); return !i.isNull && i.width * i.height > 0.3 * min(k.width * k.height, r.width * r.height) }) {
                keep.append(r)
            }
        }
        return keep
    }

    private func detect(_ buf: CVPixelBuffer, orientation: CGImagePropertyOrientation, size: CGSize) {
        guard detectHeads else { if !heads.isEmpty { heads = [] }; return }
        guard !busy, !detectorFailed else { return }
        busy = true
        let recognize = recognize
        queue.async { [weak self] in
            guard let self else { return }
            if self.detector == nil { self.detector = self.makeDetector(); self.detectorFailed = self.detector == nil }
            let up = CIImage(cvPixelBuffer: buf).oriented(orientation)
            let img = up.transformed(by: CGAffineTransform(translationX: -up.extent.minX, y: -up.extent.minY))
            var faces: [CGRect] = []
            var sigs: [[Float]?] = []
            if let detector = self.detector {
                faces = self.detectTiled(detector, img)
                if recognize {
                    // Signatures for the 5 largest faces (full-resolution crops).
                    let order = faces.indices.sorted { faces[$0].width > faces[$1].width }.prefix(5)
                    sigs = Array(repeating: nil, count: faces.count)
                    for i in order { sigs[i] = FaceID.shared.signature(faces[i], in: img, renderer: self.renderer) }
                }
                if faces.count != self.lastCount { self.lastCount = faces.count; print("[MP] faces \(faces.count), sigs \(sigs.compactMap { $0 }.count)") }
            }
            let upright = img.extent.size
            DispatchQueue.main.async {
                self.imageSize = upright
                self.heads = self.tracker.update(faces: faces, sigs: sigs)
                self.busy = false
            }
        }
    }

    /// Aspect-fill mapping from normalized image coords to view points.
    func toView(_ x: CGFloat, _ y: CGFloat, in view: CGSize) -> CGPoint {
        let s = max(view.width / imageSize.width, view.height / imageSize.height)
        let ox = (view.width - imageSize.width * s) / 2, oy = (view.height - imageSize.height * s) / 2
        return CGPoint(x: ox + x * imageSize.width * s, y: oy + y * imageSize.height * s)
    }
    func viewScale(in view: CGSize) -> CGFloat { max(view.width / imageSize.width, view.height / imageSize.height) * imageSize.width }
}

struct CameraBackground: UIViewRepresentable {
    let engine: HeadEngine
    func makeUIView(context: Context) -> UIView {
        if engine.useAR {
            let v = ARSCNView(); v.session = engine.session; v.automaticallyUpdatesLighting = false
            return v
        }
        let v = PlayerView(); v.playerLayer.player = engine.player; v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ v: UIView, context: Context) { (v as? PlayerView)?.playerLayer.player = engine.player }
    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
