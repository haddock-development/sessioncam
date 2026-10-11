import ObjectCapture
import Photogrammetry
import SwiftUI

/// WP3: Object Capture on-device (iOS 17) - aus Video-Scan wird USDZ-Mesh
final class ObjectCaptureModel: ObservableObject, ObjectCaptureSessionDelegate {
    let session = ObjectCaptureSession()
    @Published var stateText = "IDLE"
    @Published var modelURL: URL?
    @Published var sessionRunning = false
    private var captureDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd_HHmmss"
        return docs.appendingPathComponent("mesh_\(df.string(from: Date()))")
    }
    private var dir: URL?

    func start() {
        dir = captureDir()
        try? FileManager.default.createDirectory(at: dir!, withIntermediateDirectories: true)
        session.delegate = self
        session.start(detectMode: false)
        sessionRunning = true
        stateText = "SCANNE (Objekt umkreisen)"
    }

    func objectCaptureSession(_ session: ObjectCaptureSession, didUpdate state: ObjectCaptureSession.Status) {
        DispatchQueue.main.async {
            switch state {
            case .ready: self.stateText = "BEREIT - Objekt umkreisen"
            case .detecting: self.stateText = "OBJEKT ERKENNEN"
            case .capturing: self.stateText = "ERFASSSE... weiter drehen"
            case .finishing: self.stateText = "VERARBEITE..."
            case .completed: self.stateText = "ERFASST - Rekonstruktion startet"
            case .failed(let error): self.stateText = "FEHLER: \(error.localizedDescription)"
            @unknown default: self.stateText = "?"
            }
            if case .completed = state { self.reconstruct() }
        }
    }

    func complete() { session.complete() }

    private func reconstruct() {
        guard let dir else { return }
        let out = dir.appendingPathComponent("model.usdz")
        do {
            let pg = try PhotogrammetrySession(input: dir)
            try pg.process(requests: [.modelFile(url: out, detail: .medium)])
            Task {
                for await output in pg.outputs {
                    if case .requestComplete(let request, let result) = output,
                       case .modelFile = request {
                        if case .success = result {
                            DispatchQueue.main.async { self.modelURL = out; self.stateText = "FERTIG: model.usdz" }
                        }
                    }
                }
            }
        } catch {
            stateText = "REKO-FEHLER: \(error.localizedDescription)"
        }
    }
}

struct ObjectCaptureScreen: View {
    @StateObject private var model = ObjectCaptureModel()

    var body: some View {
        VStack(spacing: 12) {
            ObjectCaptureUIView(session: model.session)
                .ignoresSafeArea()
            Text(model.stateText).font(.headline).padding(8)
                .background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(10)
            if model.sessionRunning && model.modelURL == nil {
                Button("Erfassung abschliessen") { model.complete() }
                    .buttonStyle(.borderedProminent).padding(.bottom, 12)
            }
            if let url = model.modelURL {
                ShareLink(item: url) {
                    Text("USDZ teilen").padding().background(Color.blue).foregroundColor(.white).cornerRadius(12)
                }
                .padding(.bottom, 12)
            }
        }
        .navigationTitle("3D-Mesh")
    }
}

struct ObjectCaptureUIView: UIViewRepresentable {
    let session: ObjectCaptureSession

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .black
        // ObjectCaptureSession liefert Frames selbst; iOS 17 rendert via eigenen Layer-Flow.
        // Minimale Einbindung: Session startet und steuert Kamera; View zeigt Status.
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
