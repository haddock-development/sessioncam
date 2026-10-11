import SwiftUI

struct ContentView: View {
    @StateObject private var model = RecorderModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("ORT (z.B. HAUPTSTR12)", text: $model.ort)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.characters)
                    TextField("ZIMMER (z.B. WOHNZIMMER)", text: $model.zimmer)
                        .textFieldStyle(.roundedBorder)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.characters)
                }
                .padding(.horizontal)

                HStack {
                    stat("Frames", "\(model.stats.frames)")
                    stat("Depth", "\(model.stats.depthFrames)")
                    stat("Pfad m", String(format: "%.1f", model.stats.pathLength))
                    stat("Dauer s", String(format: "%.0f", model.stats.elapsed))
                }
                .padding(.horizontal)

                if model.stats.isRecording {
                    Text(String(format: "%.2f m/s", model.stats.speedMps))
                        .font(.system(size: 56, weight: .bold, design: .monospaced))
                        .foregroundColor(model.stats.speedMps > 1.2 ? .red : .green)
                    Text("Ziel: 0,8-1,0 m/s · ROT = zu schnell")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button {
                    if model.stats.isRecording { model.stop() } else { model.start() }
                } label: {
                    Text(model.stats.isRecording ? "STOP" : "AUFNAHME STARTEN")
                        .font(.title2)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(model.stats.isRecording ? Color.red : Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(14)
                }
                .padding(.horizontal)

                if !model.stats.isRecording && model.stats.frames > 0 {
                    Button {
                        model.makeZip()
                    } label: {
                        Text(model.zipping ? "ZIP wird erstellt..." : "Session zippen")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue.opacity(0.85))
                            .foregroundColor(.white)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)

                    if let url = model.lastZipURL {
                        ShareLink(item: url) {
                            Text("ZIP teilen (Dateien/iCloud)")
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.orange.opacity(0.9))
                                .foregroundColor(.white)
                                .cornerRadius(14)
                        }
                        .padding(.horizontal)
                    }
                }

                Text(model.stats.statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)
            }
            .padding(.top)
            .navigationTitle("SessionCam")
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value)
                .font(.headline)
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
