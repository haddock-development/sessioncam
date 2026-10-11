import SwiftUI
import ZIPFoundation

struct SessionListView: View {
    @Binding var shareURL: URL?
    @State private var sessions: [URL] = []
    @State private var zippingName: String?

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("Noch keine Sessions. Erst aufnehmen!")
                    .foregroundColor(.secondary)
            }
            ForEach(sessions, id: \.self) { dir in
                VStack(alignment: .leading, spacing: 4) {
                    Text(dir.lastPathComponent).font(.subheadline).bold()
                    Text("\(dirSize(dir)) MB · \(frameCount(dir)) Frames")
                        .font(.caption).foregroundColor(.secondary)
                    HStack {
                        Button("ZIP") { zipSession(dir) }
                            .buttonStyle(.bordered).controlSize(.small)
                        if let shareURL, shareURL.lastPathComponent == dir.lastPathComponent + ".zip" {
                            ShareLink(item: shareURL) { Text("Teilen") }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
                .swipeActions {
                    Button(role: .destructive) { delete(dir) } label: { Text("Löschen") }
                }
            }
        }
        .navigationTitle("Sessions")
        .onAppear(perform: reload)
        .refreshable { reload() }
    }

    private func reload() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        sessions = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: []))?
            .filter { $0.hasDirectoryPath && !$0.lastPathComponent.hasSuffix(".zip") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []
    }

    private func zipSession(_ dir: URL) {
        zippingName = dir.lastPathComponent
        let zipURL = dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + ".zip")
        DispatchQueue.global(qos: .userInitiated).async {
            try? FileManager.default.removeItem(at: zipURL)
            try? FileManager.default.zipItem(at: dir, to: zipURL)
            DispatchQueue.main.async {
                shareURL = zipURL
                zippingName = nil
                reload()
            }
        }
    }

    private func delete(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        reload()
    }

    private func dirSize(_ dir: URL) -> Int {
        Int(Double(dirSizeRaw(dir)) / 1_000_000)
    }

    private func dirSizeRaw(_ dir: URL) -> Int {
        (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey])?
            .allObjects as? [URL])?
            .reduce(0) { acc, url in
                let s = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return acc + s
            } ?? 0
    }

    private func frameCount(_ dir: URL) -> Int {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return 0 }
        return meta["frames"] as? Int ?? 0
    }
}
