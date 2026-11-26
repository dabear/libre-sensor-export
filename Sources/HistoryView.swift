//  HistoryView.swift — saved scans, grouped by sensor, newest first.
import SwiftUI
import UIKit

struct HistoryView: View {
    @ObservedObject var store: ScanStore
    /// The scan open on the main screen, marked in the list.
    let openID: Date?
    let open: (ScanResult) -> Void
    @AppStorage("glucoseUnit") private var unit: GlucoseUnit = .regionDefault
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDeleteAll = false
    /// Decrypted and parsed once per scan, not on every redraw.
    @State private var exports: [Date: Export] = [:]

    private struct Section_: Identifiable {
        let id: String          // UID: Libre 3 serials are unknown, so the serial can't group them
        let title: String
        let scans: [ScanResult]
    }

    private var sections: [Section_] {
        let grouped = Dictionary(grouping: store.scans) { Hex.string($0.uid) }
        return grouped.map { uid, scans in
            let newest = scans.sorted { $0.scannedAt > $1.scannedAt }
            let e = newest.first.flatMap { exports[$0.scannedAt] }
            let serial = e?.serial ?? "–"
            let name = serial == "–" ? "UID \(Hex.string(newest.first?.uid.reversed() ?? [], separator: ":"))" : serial
            return Section_(id: uid, title: "\(name) · \(e?.patch.summary ?? "")", scans: newest)
        }
        .sorted { ($0.scans.first?.scannedAt ?? .distantPast) > ($1.scans.first?.scannedAt ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.scans) { scan in
                            Button { open(scan) } label: { row(scan) }
                                .foregroundStyle(.primary)
                                .contextMenu {
                                    if let e = exports[scan.scannedAt] {
                                        Button { UIPasteboard.general.string = makeReport(e) } label: {
                                            Label("Copy report", systemImage: "doc.text")
                                        }
                                    }
                                    Button(role: .destructive) { store.delete([scan.scannedAt]) } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                        .onDelete { offsets in store.delete(Set(offsets.map { section.scans[$0].scannedAt })) }
                    } header: {
                        Text(section.title)
                    }
                }
            }
            .overlay {
                if store.scans.isEmpty {
                    ContentUnavailableView("No saved scans", systemImage: "clock",
                                           description: Text("Every scan is saved here, on this iPhone only."))
                }
            }
            .navigationTitle("Saved scans")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete all", role: .destructive) { confirmDeleteAll = true }
                        .disabled(store.scans.isEmpty)
                }
            }
            .confirmationDialog(store.scans.count == 1 ? "Delete the saved scan?" : "Delete all \(store.scans.count) saved scans?",
                                isPresented: $confirmDeleteAll, titleVisibility: .visible) {
                Button("Delete all", role: .destructive) { store.deleteAll() }
            }
            .task(id: store.scans.count) {
                for scan in store.scans where exports[scan.scannedAt] == nil {
                    exports[scan.scannedAt] = makeExport(scan)
                }
            }
        }
    }

    private func row(_ scan: ScanResult) -> some View {
        let e = exports[scan.scannedAt]
        return HStack {
            if scan.scannedAt == openID {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    .accessibilityLabel("Open now")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(scan.scannedAt.formatted(date: .abbreviated, time: .shortened))
                if let e { Text(detail(e)).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if let e, e.trustworthy, let g = e.parsed?.trend.first?.glucose {
                Text("\(unit.format(g)) \(unit.label)").font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(glucoseColor(g))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func detail(_ e: Export) -> String {
        guard let p = e.parsed else { return e.cryptoSummary }
        if !e.trustworthy { return "CRCs don't match" }
        return "\(SensorLabels.state(p.state)) · \(p.ageHuman)"
    }
}
