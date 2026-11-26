//  ScanStore.swift — every scan, kept on this iPhone only (Application Support, file protection
//  on), so a sensor can be looked at again or compared over time. Nothing leaves the phone.
import Foundation

final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanResult] = []   // newest first

    private let url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("scans.json")

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        if let saved = try? JSONDecoder().decode([ScanResult].self, from: data) {
            scans = saved.sorted { $0.scannedAt > $1.scannedAt }
        } else {
            // Unreadable (e.g. written by a newer version): keep it aside rather than overwrite it.
            let backup = url.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
        }
    }

    func add(_ scan: ScanResult) {
        guard !scans.contains(where: { $0.scannedAt == scan.scannedAt }) else { return }
        scans.insert(scan, at: 0)
        save()
    }

    func delete(_ ids: Set<Date>) {
        scans.removeAll { ids.contains($0.scannedAt) }
        save()
    }

    func deleteAll() {
        scans = []
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(scans).write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            // A failed save only loses the history, never the scan on screen.
        }
    }
}
