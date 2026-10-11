import ARKit
import AVFoundation
import CoreMotion
import Foundation
import UIKit

/// sessioncam-v2: RGB-Video + LiDAR-Depth + Confidence + Posen + Intrinsics + Raw-IMU
/// Live: Tempo, Tracking-State, Loop-Gap. Geteilte ARSession fuer Vorschau.
final class ARKitRecorder: NSObject, ARSessionDelegate {

    struct Stats {
        var isRecording = false
        var isPaused = false
        var frames = 0
        var depthFrames = 0
        var imuSamples = 0
        var droppedVideoFrames = 0
        var speedMps: Double = 0
        var pathLength: Double = 0
        var loopGapM: Double = -1
        var elapsed: Double = 0
        var trackingText = "INITIALISIERE"
        var statusText = ""
    }

    private let ioQueue = DispatchQueue(label: "de.indoorcapture.sessioncam.io", qos: .userInitiated)
    private let motion = CMMotionManager()

    let arSession = ARSession()

    private var sessionDir: URL?
    private var depthDir: URL?
    private var posesHandle: FileHandle?
    private var imuHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var frameIndex = 0
    private var depthIndex = 0
    private var imuIndex = 0
    private var dropped = 0
    private var paused = false
    private var lastPos: SIMD3<Float>?
    private var startPos: SIMD3<Float>?
    private var lastRealTs: Double = 0
    private var virtualTs: Double = 0
    private var startTime: Double = 0
    private var speedEMA: Double = 0
    private var pathLength: Double = 0
    private var ort = ""
    private var zimmer = ""
    private var createdAt = Date()
    private var lastStats = Stats()
    private var lastTrackingRaw = ""
    private var onStats: ((Stats) -> Void)?

    var isRecording = false
    var currentStats: Stats { lastStats }

    // Session fuer Vorschau permanent laufen lassen (auch vor/ohne REC)
    func runPreview() {
        guard session?.running != true else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        arSession.delegate = self
        arSession.run(config)
    }

    func start(ort: String, zimmer: String, onStats: @escaping (Stats) -> Void) -> URL? {
        self.onStats = onStats
        runPreview()
        guard ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth]) else {
            pushStats(Stats(statusText: "FEHLER: Kein LiDAR auf diesem Geraet."))
            return nil
        }
        self.ort = sanitize(ort)
        self.zimmer = sanitize(zimmer)
        createdAt = Date()

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sessionName(), isDirectory: true)
        let depth = dir.appendingPathComponent("depth", isDirectory: true)
        try? FileManager.default.createDirectory(at: depth, withIntermediateDirectories: true)
        sessionDir = dir
        depthDir = depth

        let posesURL = dir.appendingPathComponent("poses.jsonl")
        FileManager.default.createFile(atPath: posesURL.path, contents: nil)
        posesHandle = try? FileHandle(forWritingTo: posesURL)

        let imuURL = dir.appendingPathComponent("imu.csv")
        FileManager.default.createFile(atPath: imuURL.path, contents: Data("t,gx,gy,gz,ax,ay,az\n".utf8))
        imuHandle = try? FileHandle(forWritingTo: imuURL)
        imuIndex = 0
        motion.deviceMotionUpdateFrequency = 100
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(to: ioQueue) { [weak self] dm, _ in
                guard let self, self.isRecording, let dm, let h = self.imuHandle else { return }
                self.imuIndex += 1
                let line = String(format: "%.6f,%.5f,%.5f,%.5f,%.5f,%.5f,%.5f\n",
                                  dm.timestamp, dm.rotationRate.x, dm.rotationRate.y, dm.rotationRate.z,
                                  dm.userAcceleration.x, dm.userAcceleration.y, dm.userAcceleration.z)
                h.write(line.data(using: .utf8)!)
            }
        }

        frameIndex = 0
        depthIndex = 0
        dropped = 0
        paused = false
        lastPos = nil
        startPos = nil
        lastRealTs = 0
        virtualTs = 0
        startTime = 0
        speedEMA = 0
        pathLength = 0
        isRecording = true

        UIApplication.shared.isIdleTimerDisabled = true
        pushStats(Stats(isRecording: true, statusText: "REC"))
        return dir
    }

    func pause() {
        guard isRecording else { return }
        paused = true
        pushLast("PAUSIERT")
    }

    func resume() {
        guard isRecording, paused else { return }
        paused = false
        pushLast("REC")
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        paused = false
        UIApplication.shared.isIdleTimerDisabled = false
        motion.stopDeviceMotionUpdates()
        writerInput?.markAsFinished()
        writer?.finishWriting {}
        try? imuHandle?.close()
        imuHandle = nil
        try? posesHandle?.close()
        posesHandle = nil
        let dur = max(0, virtualTs - startTime)
        writeMeta(duration: dur)
        let summary = String(format: "Fertig: %d Frames, %d Depth, %d IMU, %.1f m", frameIndex, depthIndex, imuIndex, pathLength)
        pushStats(Stats(statusText: summary))
        return sessionDir
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let ts = frame.timestamp
        if startTime == 0 { startTime = ts; virtualTs = 0; lastRealTs = ts }
        let dt = ts - lastRealTs
        lastRealTs = ts
        if !paused && isRecording { virtualTs += dt }

        // Tracking-State (auch ohne REC -> Vorschau-Badge)
        let tracking = trackingText(frame.camera.trackingState)
        let cam = frame.camera
        let t = cam.transform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if startPos == nil { startPos = pos }
        let loopGap: Double = (isRecording && startPos != nil) ? Double(distance(pos, startPos!)) : -1

        guard isRecording, !paused else {
            if lastTrackingRaw != tracking || !isRecording {
                lastTrackingRaw = tracking
                var s = lastStats
                s.trackingText = tracking
                s.loopGapM = loopGap
                s.isRecording = isRecording
                s.isPaused = paused
                pushStats(s)
            }
            return
        }

        frameIndex += 1

        var hasDepth = false
        var depthName = ""
        if let sd = frame.sceneDepth {
            depthIndex += 1
            hasDepth = true
            depthName = String(format: "%06d", depthIndex)
            let dir = depthDir!
            let dm = sd.depthMap
            let cm = sd.confidenceMap
            ioQueue.async {
                Self.writeDepth(dm, to: dir.appendingPathComponent(depthName + ".f32"))
                if let cm { Self.writeConf(cm, to: dir.appendingPathComponent(depthName + ".conf")) }
            }
        }

        if let lp = lastPos, dt > 0.0001 {
            let d = distance(pos, lp)
            pathLength += Double(d)
            speedEMA = 0.75 * speedEMA + 0.25 * min(Double(d) / dt, 5.0)
        }
        lastPos = pos

        let i = cam.intrinsics
        let ref = frame.capturedImage
        let w = CVPixelBufferGetWidth(ref)
        let h = CVPixelBufferGetHeight(ref)
        var dw = 0, dh = 0
        if let sd = frame.sceneDepth { dw = CVPixelBufferGetWidth(sd.depthMap); dh = CVPixelBufferGetHeight(sd.depthMap) }
        let tRel = String(format: "%.6f", virtualTs - startTime)
        let depthJSON = hasDepth ? "\"\(depthName)\"" : "null"
        let poseJSON = matrixJSON(t)
        let line = "{\"i\":\(frameIndex),\"t\":\(tRel),\"pose\":\(poseJSON),\"fx\":\(i.columns.0.x),\"fy\":\(i.columns.1.y),\"cx\":\(i.columns.2.x),\"cy\":\(i.columns.2.y),\"w\":\(w),\"h\":\(h),\"dw\":\(dw),\"dh\":\(dh),\"depth\":\(depthJSON)}\n"
        let lh = posesHandle
        ioQueue.async { lh?.write(line.data(using: .utf8)!) }

        appendVideo(frame: frame, ts: virtualTs)

        if frameIndex % 6 == 0 {
            pushStats(Stats(isRecording: true, isPaused: false,
                            frames: frameIndex, depthFrames: depthIndex, imuSamples: imuIndex,
                            droppedVideoFrames: dropped, speedMps: speedEMA,
                            pathLength: pathLength, loopGapM: loopGap,
                            elapsed: virtualTs - startTime, trackingText: tracking, statusText: "REC"))
        }
    }

    // MARK: - Video

    private func appendVideo(frame: ARFrame, ts: Double) {
        if writer == nil {
            let ok = startWriter(width: CVPixelBufferGetWidth(frame.capturedImage),
                                 height: CVPixelBufferGetHeight(frame.capturedImage))
            if !ok { dropped += 1; return }
        }
        guard let w = writer, let input = writerInput, let ad = adaptor else { dropped += 1; return }
        if w.status == .writing && input.isReadyForMoreMediaData {
            if !ad.append(frame.capturedImage,
                          withPresentationTime: CMTime(seconds: ts, preferredTimescale: 600)) {
                dropped += 1
            }
        } else {
            dropped += 1
        }
    }

    private func startWriter(width: Int, height: Int) -> Bool {
        guard let dir = sessionDir else { return false }
        guard let w = try? AVAssetWriter(outputURL: dir.appendingPathComponent("video.mp4"),
                                         fileType: .mp4) else { return false }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let ad = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ])
        w.add(input)
        w.startWriting()
        w.startSession(atSourceTime: CMTime(seconds: startTime, preferredTimescale: 600))
        writer = w
        writerInput = input
        adaptor = ad
        return true
    }

    // MARK: - Helpers

    private func trackingText(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "TRACKING OK"
        case .limited(.excessiveMotion): return "ZU SCHNELL BEWEGT"
        case .limited(.insufficientFeatures): return "WENIG FEATURES"
        case .limited(.relocalizing): return "RELOKALISIERE..."
        case .limited(.initializing): return "INITIALISIERE..."
        case .notAvailable: return "KEIN TRACKING"
        @unknown default: return "UNBEKANNT"
        }
    }

    private static func writeDepth(_ pb: CVPixelBuffer, to url: URL) {
        writeRaw(pb, to: url)
    }

    private static func writeConf(_ pb: CVPixelBuffer, to url: URL) {
        writeRaw(pb, to: url)
    }

    private static func writeRaw(_ pb: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: url) else { return }
        defer { try? out.close() }
        if bpr == w * MemoryLayout<UInt8>.size || bpr == w * 4 {
            out.write(Data(bytes: base, count: w * h * (bpr / w)))
        } else {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                out.write(Data(bytes: p + row * bpr, count: min(w * 4, bpr)))
            }
        }
    }

    private func matrixJSON(_ m: simd_float4x4) -> String {
        let v: [Float] = [
            m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x,
            m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y,
            m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z,
            m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w
        ]
        return "[" + v.map { String(format: "%.8f", $0) }.joined(separator: ",") + "]"
    }

    private func sessionName() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let o = ort.isEmpty ? "ORT" : ort
        let z = zimmer.isEmpty ? "RAUM" : zimmer
        return "\(df.string(from: createdAt))_\(o)_\(z)"
    }

    private func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return s.components(separatedBy: allowed.inverted).joined(separator: "").uppercased()
    }

    private func writeMeta(duration: Double) {
        guard let dir = sessionDir else { return }
        let device = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
        let meta: [String: Any] = [
            "format": "sessioncam-v2",
            "session": dir.lastPathComponent,
            "ort": ort,
            "zimmer": zimmer,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "device": device,
            "frames": frameIndex,
            "depthFrames": depthIndex,
            "imuSamples": imuIndex,
            "droppedVideoFrames": dropped,
            "pathLengthMeters": pathLength,
            "durationSeconds": duration,
            "videoOrientation": "sensorLandscape",
            "depthFormat": "float32-le raw (.f32) + confidence uint8 (.conf), dims in poses.jsonl"
        ]
        let url = dir.appendingPathComponent("meta.json")
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private func pushLast(_ status: String) {
        var s = lastStats
        s.statusText = status
        s.isPaused = paused
        pushStats(s)
    }

    private func pushStats(_ s: Stats) {
        lastStats = s
        onStats?(s)
    }
}
