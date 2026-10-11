import Foundation
import SwiftUI
import ZIPFoundation

final class RecorderModel: ObservableObject {
    @Published var ort = ""
    @Published var zimmer = ""
    @Published var stats = ARKitRecorder.Stats()
    @Published var lastZipURL: URL?
    @Published var zipping = false

    private let recorder = ARKitRecorder()
    private var timer: Timer?

    func start() {
        guard !stats.isRecording else { return }
        lastZipURL = nil
        recorder.start(ort: ort, zimmer: zimmer) { _ in }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = self.recorder.currentStats
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        recorder.stop()
        stats = recorder.currentStats
    }

    func makeZip() {
        guard !zipping else { return }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let sessionsDir = docs.appendingPathComponent("sessions", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir, includingPropertiesForKeys: nil, options: []),
            let newest = items.filter({ $0.hasDirectoryPath }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).last
        else { return }
        zipping = true
        let zipURL = sessionsDir.appendingPathComponent(newest.lastPathComponent + ".zip")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? FileManager.default.removeItem(at: zipURL)
            do {
                try FileManager.default.zipItem(at: newest, to: zipURL)
                DispatchQueue.main.async {
                    self?.lastZipURL = zipURL
                    self?.zipping = false
                }
            } catch {
                DispatchQueue.main.async { self?.zipping = false }
            }
        }
    }
}
