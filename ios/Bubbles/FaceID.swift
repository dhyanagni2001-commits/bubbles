import SwiftUI
import AVFoundation
import CoreML
import MediaPipeTasksVision

/// Renders part of an upright CIImage into a square BGRA pixel buffer (pooled per size).
final class Renderer {
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var pools: [Int: CVPixelBufferPool] = [:]

    func square(_ img: CIImage, crop: CGRect, side: Int, flip: Bool = false) -> CVPixelBuffer? {
        if pools[side] == nil {
            let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
                                        kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pools[side] = p
        }
        var out: CVPixelBuffer?
        guard let pool = pools[side], CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        let k = CGFloat(side) / crop.width
        var t = img.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: k, y: k))
        if flip { t = t.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -CGFloat(side), y: 0)) }
        ci.render(t, to: out)
        return out
    }
}

/// Face signatures: FaceNet (InceptionResnetV1, VGGFace2) on a 160 px face crop -> 512 numbers, L2-normalized.
/// The same person's signatures point the same way (cosine ~0.6+); different people ~0.3 or less.
/// Only signatures leave the phone (over Bluetooth), never photos.
final class FaceID {
    static let shared = FaceID()
    private var model: MLModel?
    private var loadFailed = false
    private let lock = NSLock()
    private var loggedError = false

    private func load() -> MLModel? {
        if let model { return model }
        guard !loadFailed else { return nil }
        let cfg = MLModelConfiguration(); cfg.computeUnits = .all
        guard let url = Bundle.main.url(forResource: "FaceNet", withExtension: "mlmodelc"),
              let m = try? MLModel(contentsOf: url, configuration: cfg) else { print("[FACE] model missing"); loadFailed = true; return nil }
        model = m
        return m
    }

    /// Square crop around a face box (normalized, top-left origin) in an upright image whose origin is (0,0).
    /// Same framing for the selfie and the live camera, so signatures compare.
    static func faceCrop(_ face: CGRect, in img: CIImage) -> CGRect {
        let W = img.extent.width, H = img.extent.height
        let cx = face.midX * W, cy = (1 - face.midY) * H        // CIImage is bottom-left origin
        let side = max(face.width * W, face.height * H) * 1.2
        return CGRect(x: cx - side / 2, y: cy - side / 2, width: side, height: side)
    }

    /// Signature of the face at `face` (normalized, top-left) in `img`. Nil if too small or the model is missing.
    func signature(_ face: CGRect, in img: CIImage, renderer: Renderer, flip: Bool = false) -> [Float]? {
        let crop = Self.faceCrop(face, in: img)
        guard crop.width >= 24 else { return nil }            // too few pixels to say anything
        guard crop.minX >= -crop.width * 0.15, crop.minY >= -crop.width * 0.15,
              crop.maxX <= img.extent.width + crop.width * 0.15, crop.maxY <= img.extent.height + crop.width * 0.15 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let m = load() else { return nil }
        guard let px = renderer.square(img, crop: crop, side: 160, flip: flip) else { print("[FACE] render failed"); return nil }
        let arr: MLMultiArray
        do {
            let input = try MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: px)])
            let out = try m.prediction(from: input)
            guard let a = out.featureValue(for: "embedding")?.multiArrayValue else { print("[FACE] no embedding output: \(out.featureNames)"); return nil }
            arr = a
        } catch { if !loggedError { loggedError = true; print("[FACE] predict failed: \(error)") }; return nil }
        var v = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { v[i] = arr[i].floatValue }
        return Self.normalized(v)
    }

    static func normalized(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var s: Float = 0
        for i in a.indices { s += a[i] * b[i] }
        return s
    }
    /// 512 bytes for Bluetooth (one characteristic): int8, scaled so the largest value is 127.
    static func pack(_ v: [Float]) -> Data {
        let m = max(v.map(abs).max() ?? 1, 1e-6)
        return Data(v.map { UInt8(bitPattern: Int8(max(-127, min(127, ($0 / m * 127).rounded())))) })
    }
    static func unpack(_ d: Data) -> [Float]? {
        guard d.count == 512 else { return nil }
        return normalized(d.map { Float(Int8(bitPattern: $0)) })
    }
}

// MARK: - Selfie: takes your face signature (front camera, several frames averaged)

@Observable final class SelfieCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var status = "Look at the camera"
    var progress = 0.0
    var available = true
    var result: [Float]?

    @ObservationIgnored private let queue = DispatchQueue(label: "selfie")
    @ObservationIgnored private var detector: FaceDetector?
    @ObservationIgnored private let renderer = Renderer()
    @ObservationIgnored private var collecting = false
    @ObservationIgnored private var samples: [[Float]] = []
    @ObservationIgnored private var frame = 0
    static let needed = 8

    func start() {
        queue.async { [self] in
            guard session.inputs.isEmpty else { session.startRunning(); return }
            guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
                  let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) else {
                DispatchQueue.main.async { self.available = false; self.status = "No front camera here" }
                return
            }
            session.beginConfiguration()
            session.sessionPreset = .hd1280x720
            session.addInput(input)
            let out = AVCaptureVideoDataOutput()
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.alwaysDiscardsLateVideoFrames = true
            out.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(out) { session.addOutput(out) }
            if let c = out.connection(with: .video) {
                if c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }   // portrait, upright
                if c.isVideoMirroringSupported { c.automaticallyAdjustsVideoMirroring = false; c.isVideoMirrored = false }
            }
            session.commitConfiguration()
            let o = FaceDetectorOptions()
            o.baseOptions.modelAssetPath = Bundle.main.path(forResource: "blaze_face_short_range", ofType: "tflite") ?? ""
            o.runningMode = .image
            o.minDetectionConfidence = 0.6
            detector = try? FaceDetector(options: o)
            session.startRunning()
        }
    }
    func stop() { queue.async { [self] in session.stopRunning() } }

    func capture() {
        queue.async { [self] in samples = []; collecting = true }
        status = "Hold still…"; progress = 0; result = nil
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Runs on `queue`.
        frame += 1
        guard collecting, frame % 3 == 0, let buf = CMSampleBufferGetImageBuffer(sb), let detector else { return }
        let img = CIImage(cvPixelBuffer: buf)
        let W = img.extent.width, H = img.extent.height
        guard let mp = try? MPImage(pixelBuffer: buf, orientation: .up), let r = try? detector.detect(image: mp) else { return }
        guard r.detections.count == 1, let b = r.detections.first?.boundingBox else {
            let n = r.detections.count
            DispatchQueue.main.async { self.status = n == 0 ? "No face found, look at the camera" : "Only you in the photo, please" }
            return
        }
        let face = CGRect(x: b.minX / W, y: b.minY / H, width: b.width / W, height: b.height / H)
        guard face.width > 0.2 else { DispatchQueue.main.async { self.status = "Come closer" }; return }
        // The live camera may see either side of your face: learn both.
        for flip in [false, true] {
            if let s = FaceID.shared.signature(face, in: img, renderer: renderer, flip: flip) { samples.append(s) }
        }
        let p = min(1, Double(samples.count) / Double(Self.needed * 2))
        var done: [Float]?
        if samples.count >= Self.needed * 2 {
            collecting = false
            var avg = [Float](repeating: 0, count: samples[0].count)
            for s in samples { for i in avg.indices { avg[i] += s[i] } }
            done = FaceID.normalized(avg)
        }
        DispatchQueue.main.async {
            self.progress = p
            if let done { self.result = done; self.status = "Got it" } else { self.status = "Hold still… turn your head a little" }
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView { let v = PreviewView(); v.layer0.session = session; v.layer0.videoGravity = .resizeAspectFill; return v }
    func updateUIView(_ v: PreviewView, context: Context) {}
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layer0: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

/// "Take your photo": nearby Bubbles users recognise you by it. Only a face signature is kept.
struct SelfieStep: View {
    var skippable = true
    let done: ([Float]?) -> Void
    @State private var cam = SelfieCamera()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Take your photo").font(Ink.bangers(32))
            Text("Your bubble follows your face, even from across the room. Only a face signature is kept and shared with nearby Bubbles phones, never the photo.")
                .font(.system(size: 14)).opacity(0.75)
            ZStack {
                if cam.available { CameraPreview(session: cam.session).scaleEffect(x: -1, y: 1) } else { Color.black }
                Circle().stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [8, 6])).padding(40)
                VStack {
                    Spacer()
                    Text(cam.status).font(Ink.bangers(18)).foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6).background(Capsule().fill(Ink.chip))
                    ProgressView(value: cam.progress).tint(Ink.red).padding(.horizontal, 30).padding(.bottom, 14)
                }
            }
            .frame(maxWidth: .infinity).aspectRatio(3 / 4, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(Ink.ink, lineWidth: 3))
            Spacer(minLength: 0)
            if let r = cam.result {
                MangaButton(title: "USE THIS") { done(r) }
                MangaButton(title: "RETAKE", filled: false) { cam.capture() }
            } else {
                MangaButton(title: "TAKE PHOTO") { cam.capture() }.disabled(!cam.available)
                if skippable { MangaButton(title: "SKIP", filled: false) { done(nil) } }
            }
        }
        .onAppear { cam.start() }
        .onDisappear { cam.stop() }
    }
}
