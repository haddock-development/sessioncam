import RealityKit
import SwiftUI

/// WP3: Object Capture on-device (iOS 17) - Scan -> USDZ-Mesh, Realitaet-API-Flow
@MainActor
final class ObjectCaptureModel: ObservableObject, ObjectCaptureSessionDelegate {
    let session = ObjectCaptureSession()
    @Published var stateText = "IDLE"
    @Published var modelURL: URL?
    @Published var sessionRunning = false
    private var dir: URL?

    func start() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let d = docs.appendingPathComponent("mesh_\(df.string(from: Date()))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        session.delegate = self
        session.start(imagesDirectory: d)
        sessionRunning = true
        stateText = "INITIALISIERE"
    }

    nonisolated func objectCaptureSession(_ session: ObjectCaptureSession, didUpdate state: ObjectCaptureSession.Status) {
        DispatchQueue.main.async {
            switch state {
            case .initializing: self.stateText = "INITIALISIERE..."
            case .ready: self.stateText = "BEREIT - Weiter fuer Objekt-Erkennung"
            case .detecting: self.stateText = "OBJEKT ERKENNEN"
            case .capturing: self.stateText = "ERFASSE... Objekt umkreisen"
            case .finishing: self.stateText = "ABSCHLIESSEN..."
            case .completed: self.stateText = "ERFASST - Rekonstruktion laeuft"
            case .failed(let error): self.stateText = "FEHLER: \(error.localizedDescription)"
            @unknown default: self.stateText = "?"
            }
            if case .completed = state { self.reconstruct() }
        }
    }

    func startCapturing() { session.startCapturing() }
    func startDetecting() { _ = session.startDetecting() }
    func finishScan() { session.finish() }

    private func reconstruct() {
        guard let dir else { return }
        let out = dir.appendingPathComponent("model", conformingTo: .usdz)
        do {
            let pg = try PhotogrammetrySession(input: dir)
            try pg.process(requests: [.modelFile(url: out, detail: .reduced)])
            Task {
                for try await output in pg.outputs {
                    if case .processingComplete = output {
                        DispatchQueue.main.async { self.modelURL = out; self.stateText = "FERTIG: model.usdz" }
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
                HStack(spacing: 10) {
                    Button("Erkennen") { model.startDetecting() }
                        .buttonStyle(.bordered)
                    Button("Capture") { model.startCapturing() }
                        .buttonStyle(.bordered)
                    Button("Fertig") { model.finishScan() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 12)
            }
            if let url = model.modelURL {
                ShareLink(item: url) {
                    Text("USDZ teilen").padding()
                        .background(Color.blue).foregroundColor(.white).cornerRadius(12)
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
        let lbl = UILabel()
        lbl.text = "Objekt-Scan:\nObjekt platzieren, ERKENNEN, dann CAPTURE\nund langsam umkreisen"
        lbl.textColor = .white
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        lbl.frame = CGRect(x: 24, y: 220, width: 320, height: 120)
        v.addSubview(lbl)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
