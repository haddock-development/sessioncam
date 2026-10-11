import RealityKit
import SwiftUI

/// WP3: Object Capture on-device (iOS 17) - Scan -> USDZ-Mesh (RealityKit-API, polling)
@MainActor
final class ObjectCaptureModel: ObservableObject {
    let session = ObjectCaptureSession()
    @Published var stateText = "IDLE"
    @Published var modelURL: URL?
    @Published var sessionRunning = false
    private var dir: URL?
    private var reconstructed = false
    private var timer: Timer?

    func start() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let d = docs.appendingPathComponent("mesh_\(df.string(from: Date()))")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dir = d
        session.start(imagesDirectory: d)
        sessionRunning = true
        stateText = "INITIALISIERE"
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    private func poll() {
        switch session.state {
        case .initializing: stateText = "INITIALISIERE..."
        case .ready: stateText = "BEREIT - Weiter fuer Objekt-Erkennung"
        case .detecting: stateText = "OBJEKT ERKENNEN"
        case .capturing: stateText = "ERFASSE... Objekt umkreisen"
        case .finishing: stateText = "ABSCHLIESSEN..."
        case .completed:
            stateText = "ERFASST - Rekonstruktion laeuft"
            if !reconstructed { reconstructed = true; reconstruct() }
        case .failed: stateText = "FEHLER"
        @unknown default: break
        }
    }

    func startDetecting() { _ = session.startDetecting() }
    func startCapturing() { session.startCapturing() }
    func finishScan() { session.finish() }

    private func reconstruct() {
        guard let dir, let out = dir.children?.first(where: { $0.pathExtension == "usdz" }) ?? nil else {
            guard let dir else { return }
            do { try reconstructTo(dir, out: dir.appendingPathComponent("model", conformingTo: .usdz)) }
            catch { stateText = "REKO-FEHLER: \(error.localizedDescription)" }
            return
        }
        modelURL = out
        stateText = "FERTIG: \(out.lastPathComponent)"
    }

    private func reconstructTo(_ dir: URL, out: URL) throws {
        let pg = try PhotogrammetrySession(input: dir)
        try pg.process(requests: [.modelFile(url: out, detail: .reduced)])
        Task { [weak self] in
            for try await output in pg.outputs {
                if case .processingComplete = output {
                    DispatchQueue.main.async {
                        self?.modelURL = out
                        self?.stateText = "FERTIG: \(out.lastPathComponent)"
                    }
                }
            }
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
        lbl.text = "Objekt-Scan:\nERKENNEN -> CAPTURE -> langsam umkreisen -> FERTIG"
        lbl.textColor = .white
        lbl.textAlignment = .center
        lbl.numberOfLines = 0
        lbl.frame = CGRect(x: 24, y: 220, width: 320, height: 120)
        v.addSubview(lbl)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}
