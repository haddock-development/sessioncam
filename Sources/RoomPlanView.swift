import RoomPlan
import SwiftUI

/// WP2: RoomPlan-Grundriss in-app (iOS 17, LiDAR-Geraet)
struct RoomCaptureUIView: UIViewRepresentable {
    @Binding var capturedRoom: CapturedRoom?
    @Binding var scanning: Bool

    func makeUIView(context: Context) -> RoomCaptureView {
        let view = RoomCaptureView(frame: .zero)
        let session = RoomCaptureSession()
        view.session = session
        session.delegate = context.coordinator
        context.coordinator.captureView = view
        session.run(configuration: context.coordinator.config)
        return view
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, RoomCaptureSessionDelegate {
        let config = RoomCaptureSessionConfig()
        weak var captureView: RoomCaptureView?
        var parent: RoomCaptureUIView

        init(_ parent: RoomCaptureUIView) { self.parent = parent }

        func captureSession(_ session: RoomCaptureSession, didEndWith capturedRoom: CapturedRoom?, error: Error?) {
            DispatchQueue.main.async {
                self.parent.capturedRoom = capturedRoom
                self.parent.scanning = false
            }
        }
    }
}

struct RoomPlanScreen: View {
    @ObservedObject var model: RecorderModel
    @State private var capturedRoom: CapturedRoom?
    @State private var scanning = true
    @State private var saved = ""

    var body: some View {
        VStack(spacing: 0) {
            if capturedRoom == nil {
                RoomCaptureUIView(capturedRoom: $capturedRoom, scanning: $scanning)
                    .ignoresSafeArea()
                Button("Scan beenden") { model.roomSession?.stop() }
                    .padding(8).background(.black.opacity(0.6)).foregroundColor(.white).cornerRadius(10)
                    .padding(.bottom, 12)
            } else {
                FloorPlanView(room: capturedRoom!)
                    .padding(8)
                Text("Wände: \(capturedRoom!.walls.count) · Türen: \(capturedRoom!.doors.count) · Objekte: \(capturedRoom!.objects.count)")
                    .font(.caption).foregroundColor(.secondary)
                Button("floorplan.json in letzte Session speichern") {
                    saved = model.saveFloorplan(room: capturedRoom!)
                }
                .buttonStyle(.borderedProminent).padding(8)
                if !saved.isEmpty { Text(saved).font(.caption).foregroundColor(.green) }
                Button("Neuer Scan") { capturedRoom = nil; scanning = true }
                    .buttonStyle(.bordered).padding(.bottom, 12)
                Spacer()
            }
        }
        .onAppear { model.roomSession = RoomCaptureSession() }
        .navigationTitle("Grundriss")
    }
}

/// Top-down 2D-Render der Wnde/Türen aus CapturedRoom-Transforms
struct FloorPlanView: View {
    let room: CapturedRoom

    var body: some View {
        Canvas { ctx, size in
            var segs: [(SIMD2<Float>, SIMD2<Float>, Color)] = []
            func segsOf(_ surfaces: [CapturedRoom.Surface], _ color: Color) {
                for s in surfaces {
                    let p = s.transform.columns.3
                    let dir = SIMD2<Float>(s.transform.columns.0.x, s.transform.columns.0.z)
                    let len = s.dimensions.x / 2
                    let a = SIMD2<Float>(p.x, p.z) - dir * len
                    let b = SIMD2<Float>(p.x, p.z) + dir * len
                    segs.append((a, b, color))
                }
            }
            segsOf(room.walls, .black)
            segsOf(room.doors.map { $0 as CapturedRoom.Surface }, .orange)
            segsOf(room.windows.map { $0 as CapturedRoom.Surface }, .cyan)
            guard !segs.isEmpty else { return }
            var minX: Float = .greatestFiniteMagnitude, maxX: Float = -.greatestFiniteMagnitude
            var minZ: Float = .greatestFiniteMagnitude, maxZ: Float = -.greatestFiniteMagnitude
            for (a, b, _) in segs {
                for pnt in [a, b] {
                    minX = min(minX, pnt.x); maxX = max(maxX, pnt.x)
                    minZ = min(minZ, pnt.y); maxZ = max(maxZ, pnt.y)
                }
            }
            let span = max(maxX - minX, maxZ - minZ, 0.1)
            let scale = min(size.width, size.height) / CGFloat(span) * 0.85
            let offX = (size.width - CGFloat(maxX - minX) * scale) / 2
            let offY = (size.height - CGFloat(maxZ - minZ) * scale) / 2
            func toXY(_ pnt: SIMD2<Float>) -> CGPoint {
                CGPoint(x: CGFloat(pnt.x - minX) * scale + offX,
                        y: CGFloat(pnt.y - minZ) * scale + offY)
            }
            for (a, b, color) in segs {
                var path = Path()
                path.move(to: toXY(a))
                path.addLine(to: toXY(b))
                ctx.stroke(path, with: .color(color), lineWidth: color == .black ? 3 : 2)
            }
        }
        .background(Color(white: 0.96))
        .cornerRadius(12)
    }
}
