import SwiftUI

struct ContentView: View {
    @StateObject private var model = RecorderModel()

    var body: some View {
        TabView {
            captureView
                .tabItem { Label("Aufnahme", systemImage: "record.circle") }
            NavigationView {
                SessionListView(shareURL: $model.shareURL)
            }
            .tabItem { Label("Sessions", systemImage: "list.bullet") }
        }
    }

    private var captureView: some View {
        ZStack {
            CameraPreview(session: model.recorder.arSession)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                trackingBadge

                if model.stats.isRecording {
                    VStack(spacing: 4) {
                        Text(String(format: "%.2f m/s", model.stats.speedMps))
                            .font(.system(size: 52, weight: .bold, design: .monospaced))
                            .foregroundColor(model.stats.speedMps > 1.2 ? .red : .green)
                        Text("Ziel 0,8-1,0 m/s")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(10)
                    .background(.black.opacity(0.55))
                    .cornerRadius(12)

                    if model.stats.loopGapM >= 0 {
                        Text(String(format: "Loop-Gap: %.2f m %@", model.stats.loopGapM,
                                    model.stats.loopGapM < 0.35 ? "✓" : ""))
                            .font(.headline)
                            .foregroundColor(model.stats.loopGapM < 0.35 ? .green : .yellow)
                            .padding(8)
                            .background(.black.opacity(0.55))
                            .cornerRadius(10)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    HStack {
                        stat("Frames", "\(model.stats.frames)")
                        stat("Depth", "\(model.stats.depthFrames)")
                        stat("IMU", "\(model.stats.imuSamples)")
                        stat("Pfad m", String(format: "%.1f", model.stats.pathLength))
                    }
                    .padding(10)
                    .background(.black.opacity(0.55))
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    if model.stats.isRecording {
                        if model.stats.isPaused {
                            Button { model.resume() } label: {
                                Text("WEITER").font(.headline).frame(maxWidth: .infinity).padding()
                                    .background(Color.orange).foregroundColor(.white).cornerRadius(14)
                            }
                        } else {
                            Button { model.pause() } label: {
                                Text("PAUSE").font(.headline).frame(maxWidth: .infinity).padding()
                                    .background(Color.orange.opacity(0.8)).foregroundColor(.white).cornerRadius(14)
                            }
                        }
                        Button { model.stop() } label: {
                            Text("STOP").font(.headline).frame(maxWidth: .infinity).padding()
                                .background(Color.red).foregroundColor(.white).cornerRadius(14)
                        }
                    } else {
                        VStack(spacing: 8) {
                            TextField("ORT", text: $model.ort)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.characters)
                            TextField("ZIMMER", text: $model.zimmer)
                                .textFieldStyle(.roundedBorder)
                                .disableAutocorrection(true)
                                .textInputAutocapitalization(.characters)
                        }
                        .padding(.horizontal)
                        .background(.black.opacity(0.4))
                        .cornerRadius(12)

                        Button { model.start() } label: {
                            Text("AUFNAHME STARTEN").font(.title3).bold()
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.green).foregroundColor(.white).cornerRadius(14)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 6)

                if !model.stats.isRecording && model.stats.frames > 0 {
                    NavigationLink {
                        SessionListView(shareURL: $model.shareURL)
                    } label: {
                        Text("Session zippen & teilen -> Tab Sessions").font(.footnote)
                            .foregroundColor(.white.opacity(0.9))
                    }
                    .padding(.bottom, 12)
                }
            }
            .padding(.top)
        }
        .navigationViewStyle(.stack)
    }

    private var trackingBadge: some View {
        let t = model.stats.trackingText
        let color: Color = t == "TRACKING OK" ? .green : (t.contains("INITIAL") ? .yellow : .red)
        return Text(t)
            .font(.caption).bold()
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(color.opacity(0.85)).foregroundColor(.white)
            .cornerRadius(10)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.subheadline).bold().monospacedDigit().foregroundColor(.white)
            Text(label).font(.caption2).foregroundColor(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }
}
