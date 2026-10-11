import SwiftUI
import ARKit
import SceneKit

/// Live-Kamerabild + Live-Punktewolke (geteilte ARSession des Recorders).
struct CameraPreview: UIViewRepresentable {
    let session: ARSession
    let cloudNode: SCNNode

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.backgroundColor = .black
        v.scene.rootNode.addChildNode(cloudNode)
        return v
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
