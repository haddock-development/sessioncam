import ARKit
import AVFoundation
import Foundation
import UIKit

/// Kernelement: nimmt eine ARKit-Session auf (RGB-Video + LiDAR-Depth + Posen + Intrinsics)
/// und schreibt direkt unser Pipeline-Format ("sessioncam-v1").
final class ARKitRecorder: NSObject, ARSessionDelegate {

    struct Stats {
        var isRecording = false
        var frames = 0
        var depthFrames = 0
        var droppedVideoFrames = 0
        var speedMps: Double = 0
        var pathLength: Double = 0
        var elapsed: Double = 0
        var statusText = ""
    }

    private let ioQueue = DispatchQueue(label: "de.indoorcapture.sessioncam.io", qos: .userInitiated)

    private var session: ARSession?
    private var sessionDir: URL?
    private var depthDir: URL?
    private var posesHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?

    private var frameIndex = 0
    private var depthIndex = 0
    private var dropped = 0
    private var lastPos: SIMD3<Float>?
    private var lastTime: Double = 0
    private var startTime: Double = 0
    private var speedEMA: Double = 0
    private var pathLength: Double = 0
    private var ort = ""
    private var zimmer = ""
    private var createdAt = Date()
    private var lastStats = Stats()
    private var onStats: ((Stats) -> Void)?

    var isRecording = false
    var currentStats: Stats { lastStats }

    func start(ort: String, zimmer: String, onStats: @escaping (Stats) -> Void) -> URL? {
        self.onStats = onStats
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

        frameIndex = 0
        depthIndex = 0
        dropped = 0
        lastPos = nil
        lastTime = 0
        startTime = 0
        speedEMA = 0
        pathLength = 0
        isRecording = true

        let config = ARWorldTrackingConfiguration()
        config.frameSemantics = [.sceneDepth]
        config.worldAlignment = .gravity
        config.environmentTexturing = .none
        let arSession = ARSession()
        arSession.delegate = self
        arSession.run(config)
        session = arSession

        UIApplication.shared.isIdleTimerDisabled = true
        pushStats(Stats(isRecording: true, statusText: "REC"))
        return dir
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        UIApplication.shared.isIdleTimerDisabled = false
        session?.pause()
        session = nil

        writerInput?.markAsFinished()
        let w = writer
        w?.finishWriting {}

        let dur = max(0, lastTime - startTime)
        try? posesHandle?.close()
        posesHandle = nil
        writeMeta(duration: dur)
        let summary = String(format: "Fertig: %d Frames, %d Depth, %.1f m Pfad", frameIndex, depthIndex, pathLength)
        pushStats(Stats(statusText: summary))
        return sessionDir
    }

    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRecording else { return }
        if startTime == 0 { startTime = frame.timestamp; lastTime = frame.timestamp }
        frameIndex += 1
        let ts = frame.timestamp
        let cam = frame.camera
        let t = cam.transform
        let pos = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)

        var hasDepth = false
        var depthName = ""
        if let dm = frame.sceneDepth?.depthMap {
            depthIndex += 1
            hasDepth = true
            depthName = String(format: "%06d.f32", depthIndex)
            let dir = depthDir!
            ioQueue.async { Self.writeDepth(dm, to: dir.appendingPathComponent(depthName)) }
        }

        let dt = ts - lastTime
        if let lp = lastPos, dt > 0.0001 {
            let d = distance(pos, lp)
            pathLength += Double(d)
            let inst = Double(d) / dt
            speedEMA = 0.75 * speedEMA + 0.25 * min(inst, 5.0)
        }
        lastPos = pos
        lastTime = ts

        let i = cam.intrinsics
        let ref = frame.capturedImage
        let w = CVPixelBufferGetWidth(ref)
        let h = CVPixelBufferGetHeight(ref)
        let tRel = String(format: "%.6f", ts - startTime)
        let depthJSON = hasDepth ? "\"\(depthName)\"" : "null"
        let poseJSON = matrixJSON(t)
        let line = "{\"i\":\(frameIndex),\"t\":\(tRel),\"pose\":\(poseJSON),\"fx\":\(i.columns.0.x),\"fy\":\(i.columns.1.y),\"cx\":\(i.columns.2.x),\"cy\":\(i.columns.2.y),\"w\":\(w),\"h\":\(h),\"depth\":\(depthJSON)}\n"
        let lh = posesHandle
        ioQueue.async { lh?.write(line.data(using: .utf8)!) }

        appendVideo(frame: frame, ts: ts)

        if frameIndex % 6 == 0 {
            pushStats(Stats(isRecording: true,
                            frames: frameIndex,
                            depthFrames: depthIndex,
                            droppedVideoFrames: dropped,
                            speedMps: speedEMA,
                            pathLength: pathLength,
                            elapsed: ts - startTime,
                            statusText: "REC"))
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

    private static func writeDepth(_ pb: CVPixelBuffer, to url: URL) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: url) else { return }
        defer { try? out.close() }
        if bpr == w * 4 {
            out.write(Data(bytes: base, count: w * h * 4))
        } else {
            let p = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                out.write(Data(bytes: p + row * bpr, count: w * 4))
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
            "format": "sessioncam-v1",
            "session": dir.lastPathComponent,
            "ort": ort,
            "zimmer": zimmer,
            "createdAt": ISO8601DateFormatter().string(from: createdAt),
            "device": device,
            "frames": frameIndex,
            "depthFrames": depthIndex,
            "droppedVideoFrames": dropped,
            "pathLengthMeters": pathLength,
            "durationSeconds": duration,
            "videoOrientation": "sensorLandscape",
            "depthFormat": "float32-le raw, dims in poses.jsonl"
        ]
        let url = dir.appendingPathComponent("meta.json")
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
    }

    private func pushStats(_ s: Stats) {
        lastStats = s
        onStats?(s)
    }
}
