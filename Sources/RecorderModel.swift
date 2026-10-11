import Foundation
import SwiftUI
import RoomPlan
import simd

final class RecorderModel: ObservableObject {
    @Published var ort = ""
    @Published var zimmer = ""
    @Published var stats = ARKitRecorder.Stats()
    @Published var checklist = ARKitRecorder.Checklist()
    @Published var shareURL: URL?
    @Published var zipping = false

    let recorder = ARKitRecorder()
    var roomSession: RoomCaptureSession?

    func saveFloorplan(room: CapturedRoom) -> String {
        func surf(_ s: CapturedRoom.Surface) -> [String: Any] {
            genericSurf(s.dimensions, s.transform, conf: "(s.confidence)")
        }
        func surfObj(_ o: CapturedRoom.Object) -> [String: Any] {
            var d = genericSurf(o.dimensions, o.transform, conf: "(o.confidence)")
            d["category"] = "\(o.category)"
            return d
        }
        func genericSurf(_ dims: simd_float3, _ m: simd_float4x4, conf: String) -> [String: Any] {
                        let v: [Float] = [
                m.columns.0.x, m.columns.1.x, m.columns.2.x, m.columns.3.x,
                m.columns.0.y, m.columns.1.y, m.columns.2.y, m.columns.3.y,
                m.columns.0.z, m.columns.1.z, m.columns.2.z, m.columns.3.z,
                m.columns.0.w, m.columns.1.w, m.columns.2.w, m.columns.3.w]
            return ["dimensions": [dims.x, dims.y, dims.z],
                    "transform": v, "confidence": conf]
        }
        let json: [String: Any] = [
            "format": "floorplan-v1",
            "createdAt": ISO8601DateFormatter().string(from: Date()),
            "walls": room.walls.map(surf),
            "doors": room.doors.map(surf),
            "windows": room.windows.map(surf),
            "openings": room.openings.map(surf),
            "objects": room.objects.map { surfObj($0) }
        ]
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("sessions", isDirectory: true)
        let items = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: []))?.filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasSuffix(".zip") }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard let newest = items.last else { return "Keine Session vorhanden - erst aufnehmen" }
        let url = newest.appendingPathComponent("floorplan.json")
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { return "Serialisierung fehlgeschlagen" }
        do { try data.write(to: url); return "Gespeichert: \(url.lastPathComponent)" }
        catch { return "Fehler: \(error.localizedDescription)" }
    }
    private var timer: Timer?

    init() {
        recorder.runPreview()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = self.recorder.currentStats
            self.checklist = self.recorder.currentChecklist
        }
    }

    func start() {
        guard !stats.isRecording else { return }
        shareURL = nil
        recorder.start(ort: ort, zimmer: zimmer) { _ in }
    }

    func tick(_ item: String) { recorder.tick(item) }
    func pause() { recorder.pause() }
    func resume() { recorder.resume() }
    func stop() {
        recorder.stop()
        stats = recorder.currentStats
    }
}
