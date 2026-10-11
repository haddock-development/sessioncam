import ARKit
import AVFoundation
import CoreMotion
import Foundation
import SceneKit
import UIKit

/// sessioncam-v3: RGB + LiDAR-Depth + Confidence + Posen + Intrinsics + Raw-IMU
/// Live: Tempo, Tracking (+Guete-%), Loop-Gap, Punktewolke, Checkliste. Pause/Resume.
final class ARKitRecorder: NSObject, ARSessionDelegate {

    struct Checklist {
        var pan = false
        var perimeter = false
        var diagonal = false
        var loop = false
        var loopSuggested = false
        var active: [String] { ["pan", "perimeter", "diagonal", "loop"].filter { item in
            switch item {
            case "pan": return pan
            case "perimeter": return perimeter
            case "diagonal": return diagonal
            case "loop": return loop
            default: return false
            }
        } }
    }

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
        var qualityPct: Double = -1
        var cloudPoints = 0
        var statusText = ""
    }

    private let ioQueue = DispatchQueue(label: "de.indoorcapture.sessioncam.io", qos: .userInitiated)
    private let cloudQueue = DispatchQueue(label: "de.indoorcapture.sessioncam.cloud", qos: .utility)
    private let cloudLock = NSLock()
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()
    private var previewRunning = false

    let arSession = ARSession()
    let cloudNode = SCNNode()

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

    // Qualitaets-Timeline (B)
    private var tqNormal = 0, tqExcessive = 0, tqFeatures = 0, tqReloc = 0, tqInit = 0, tqNA = 0

    // Live-Punktewolke (A)
    private var cloudPoints: [SIMD3<Float>] = []
    private let maxCloudPoints = 90000
    private var lastCloudPush: Double = 0

    // Checkliste (C)
    private var checklist = Checklist()

    var isRecording = false
    var currentStats: Stats { lastStats }
    var currentChecklist: Checklist { checklist }

    func runPreview() {
        guard !previewRunning else { return }
        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        arSession.delegate = self
        arSession.run(config)
        previewRunning = true
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
        motion.deviceMotionUpdateInterval = 1.0 / 100.0
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(to: motionQueue) { [weak self] dm, _ in
                guard let self, self.isRecording, !self.paused, let dm, let h = self.imuHandle else { return }
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
        cloudLock.lock()
        cloudPoints.removeAll()
        cloudLock.unlock()
        tqNormal = 0; tqExcessive = 0; tqFeatures = 0; tqReloc = 0; tqInit = 0; tqNA = 0
        checklist = Checklist()
        isRecording = true

        UIApplication.shared.isIdleTimerDisabled = true
        pushStats(Stats(isRecording: true, statusText: "REC"))
        return dir
    }

    func tick(_ item: String) {
        switch item {
        case "pan": checklist.pan = true
        case "perimeter": checklist.perimeter = true
        case "diagonal": checklist.diagonal = true
        case "loop": checklist.loop = true
        default: break
        }
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
        if isRecording && !paused { virtualTs += dt }

        let tracking = trackingText(frame.camera.trackingState)
        let cam = frame.camera
        let t = cam.transform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        if startPos == nil { startPos = pos }
        let loopGap: Double = (isRecording && startPos != nil) ? Double(distance(pos, startPos!)) : -1

        if isRecording && !paused {
            switch frame.camera.trackingState {
            case .normal: tqNormal += 1
            case .limited(.excessiveMotion): tqExcessive += 1
            case .limited(.insufficientFeatures): tqFeatures += 1
            case .limited(.relocalizing): tqReloc += 1
            case .limited(.initializing): tqInit += 1
            case .notAvailable: tqNA += 1
            @unknown default: break
            }
        }

        // Live-Punktewolke (A): jede 3. Frame, downsampled, verlustfrei im Ring
        if isRecording && !paused, frameIndex % 3 == 0, let sd = frame.sceneDepth {
            let dm = sd.depthMap
            let intr = cam.intrinsics
            let pose = t
            let w0 = CVPixelBufferGetWidth(frame.capturedImage)
            let h0 = CVPixelBufferGetHeight(frame.capturedImage)
            cloudQueue.async { [weak self] in
                self?.accumulateCloud(dm, intr: intr, pose: pose, ts: ts, w0: w0, h0: h0)
            }
        }

        guard isRecording, !paused else {
            if lastTrackingRaw != tracking {
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
                Self.writeRaw(dm, to: dir.appendingPathComponent(depthName + ".f32"))
                if let cm { Self.writeRaw(cm, to: dir.appendingPathComponent(depthName + ".conf")) }
            }
        }

        if let lp = lastPos, dt > 0.0001 {
            let d = distance(pos, lp)
            pathLength += Double(d)
            speedEMA = 0.75 * speedEMA + 0.25 * min(Double(d) / dt, 5.0)
        }
        lastPos = pos

        // Auto-Vorschlag: LOOP-Tick, sobald wir nah am Start sind (C)
        if loopGap >= 0 && loopGap < 0.35 && !checklist.loop && frameIndex > 30 {
            checklist.loopSuggested = true
        }

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
            let total = tqNormal + tqExcessive + tqFeatures + tqReloc + tqInit + tqNA
            let q = total > 0 ? Double(tqNormal) / Double(total) * 100.0 : -1
            pushStats(Stats(isRecording: true, isPaused: false,
                            frames: frameIndex, depthFrames: depthIndex, imuSamples: imuIndex,
                            droppedVideoFrames: dropped, speedMps: speedEMA,
                            pathLength: pathLength, loopGapM: loopGap,
                            elapsed: virtualTs - startTime, trackingText: tracking,
                            qualityPct: q, cloudPoints: cloudPointCount(), statusText: "REC"))
        }
    }

    // MARK: - Live-Punktewolke (A)

    private func accumulateCloud(_ dm: CVPixelBuffer, intr: simd_float3x3, pose: simd_float4x4, ts: Double, w0: Int, h0: Int) {
        CVPixelBufferLockBaseAddress(dm, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(dm, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(dm) else { return }
        let dw = CVPixelBufferGetWidth(dm)
        let dh = CVPixelBufferGetHeight(dm)
        let bpr = CVPixelBufferGetBytesPerRow(dm)
        let p = base.assumingMemoryBound(to: Float.self)
        let fx = intr.columns.0.x * Float(dw) / Float(w0)
        let fy = intr.columns.1.y * Float(dh) / Float(h0)
        let cx = intr.columns.2.x * Float(dw) / Float(w0)
        let cy = intr.columns.2.y * Float(dh) / Float(h0)
        let m = pose
        var fresh: [SIMD3<Float>] = []
        fresh.reserveCapacity((dw / 8) * (dh / 8))
        for v in stride(from: 0, to: dh, by: 8) {
            for u in stride(from: 0, to: dw, by: 8) {
                let z = p[v * (bpr / 4) + u]
                if z <= 0.1 || z > 5.0 { continue }
                let x = (Float(u) - cx) * z / fx
                let y = (Float(v) - cy) * z / fy
                let zc = -z
                let wx = m.columns.0.x * x + m.columns.1.x * y + m.columns.2.x * zc + m.columns.3.x
                let wy = m.columns.0.y * x + m.columns.1.y * y + m.columns.2.y * zc + m.columns.3.y
                let wz = m.columns.0.z * x + m.columns.1.z * y + m.columns.2.z * zc + m.columns.3.z
                fresh.append(SIMD3<Float>(wx, wy, wz))
            }
        }
        cloudLock.lock()
        cloudPoints.append(contentsOf: fresh)
        if cloudPoints.count > maxCloudPoints {
            cloudPoints.removeFirst(cloudPoints.count - maxCloudPoints)
        }
        let count = cloudPoints.count
        cloudLock.unlock()
        if ts - lastCloudPush > 0.3 {
            lastCloudPush = ts
            let snapshot = snapshotCloud()
            DispatchQueue.main.async { [weak self] in
                self?.rebuildCloudNode(points: snapshot)
                var s = self?.lastStats ?? Stats()
                s.cloudPoints = count
                self?.lastStats = s
            }
        }
    }

    private func snapshotCloud() -> [SIMD3<Float>] {
        cloudLock.lock()
        defer { cloudLock.unlock() }
        return cloudPoints
    }

    private func cloudPointCount() -> Int {
        cloudLock.lock()
        defer { cloudLock.unlock() }
        return cloudPoints.count
    }

    private func rebuildCloudNode(points: [SIMD3<Float>]) {
        guard !points.isEmpty else { return }
        var vertices: [SCNVector3] = []
        vertices.reserveCapacity(points.count)
        for p in points { vertices.append(SCNVector3(p.x, p.y, p.z)) }
        let source = SCNGeometrySource(vertices: vertices)
        var indices: [Int32] = Array(0..<Int32(vertices.count))
        let idxData = Data(bytes: &indices, count: indices.count * MemoryLayout<Int32>.size)
        let element = SCNGeometryElement(data: idxData, primitiveType: .point,
                                         primitiveCount: vertices.count, bytesPerIndex: MemoryLayout<Int32>.size)
        element.pointSize = 2.0
        element.minimumPointScreenSpaceRadius = 1.0
        element.maximumPointScreenSpaceRadius = 3.0
        let geo = SCNGeometry(sources: [source], elements: [element])
        cloudNode.geometry = geo
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
        let rowBytes = min(bpr, w * 4)
        if bpr == w * 4 {
            out.write(Data(bytes: base, count: w * h * 4))
        } else {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                out.write(Data(bytes: p + row * bpr, count: rowBytes))
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
        let total = tqNormal + tqExcessive + tqFeatures + tqReloc + tqInit + tqNA
        let device = "\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"
        let meta: [String: Any] = [
            "format": "sessioncam-v3",
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
            "depthFormat": "float32-le raw (.f32) + confidence uint8 (.conf), dims in poses.jsonl",
            "trackingQuality": [
                "total": total,
                "normal": tqNormal,
                "excessiveMotion": tqExcessive,
                "insufficientFeatures": tqFeatures,
                "relocalizing": tqReloc,
                "initializing": tqInit,
                "notAvailable": tqNA,
                "normalPct": total > 0 ? Double(tqNormal) / Double(total) * 100.0 : -1
            ],
            "protocol": [
                "done": checklist.active,
                "loopAutoSuggested": checklist.loopSuggested
            ]
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
