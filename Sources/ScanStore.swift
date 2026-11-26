//  ScanStore.swift — every scan, kept on this iPhone only (Application Support, file protection
//  on), so a sensor can be looked at again or compared over time. Nothing leaves the phone.
import Foundation

final class ScanStore: ObservableObject {
    @Published private(set) var scans: [ScanResult] = []   // newest first

    /// Its own folder, excluded from iCloud and computer backups: the health data stays on this iPhone.
    private static let folder: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Scans", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        // 1.1 kept the file directly in Application Support, which is backed up: move it in
        let old = base.appendingPathComponent("scans.json"), new = dir.appendingPathComponent("scans.json")
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        return dir
    }()

    private let url = ScanStore.folder.appendingPathComponent("scans.json")

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
        // also set-aside unreadable files and leftover share files
        let fm = FileManager.default
        for f in (try? fm.contentsOfDirectory(at: ScanStore.folder, includingPropertiesForKeys: nil)) ?? []
        where f.lastPathComponent != "scans.json" { try? fm.removeItem(at: f) }
        removeExportFiles()
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
