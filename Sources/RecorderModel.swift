import Foundation
import SwiftUI
import ZIPFoundation

final class RecorderModel: ObservableObject {
    @Published var ort = ""
    @Published var zimmer = ""
    @Published var stats = ARKitRecorder.Stats()
    @Published var shareURL: URL?
    @Published var zipping = false

    let recorder = ARKitRecorder()
    private var timer: Timer?

    init() {
        // Vorschau-Session ab App-Start laufen lassen
        recorder.runPreview()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stats = self.recorder.currentStats
        }
    }

    func start() {
        guard !stats.isRecording else { return }
        shareURL = nil
        recorder.start(ort: ort, zimmer: zimmer) { _ in }
    }

    func pause() { recorder.pause() }
    func resume() { recorder.resume() }

    func stop() {
        recorder.stop()
        stats = recorder.currentStats
    }

    func reloadSessions() {}
}
