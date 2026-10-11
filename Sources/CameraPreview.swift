import SwiftUI
import ARKit
import SceneKit

/// Live-Kamerabild: teilt SICH die Session des Recorders (Vorschau auch vor dem Start).
struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
