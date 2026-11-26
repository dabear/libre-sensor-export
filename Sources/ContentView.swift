//  ContentView.swift — scan, then Overview / Readings / Technical. Saved scans and settings in
//  the toolbar.
import SwiftUI
import UIKit

enum ScanTab: String, CaseIterable, Identifiable {
    case overview = "Overview", readings = "Readings", technical = "Technical"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var nfc = NFCReader()
    @StateObject private var store = ScanStore()
    @AppStorage("glucoseUnit") private var unit: GlucoseUnit = .regionDefault
    @AppStorage("deepScan") private var deepScan = false
    @State private var export: Export?
    /// The open scan came from saved scans (or was restored at launch), not from scanning now.
    @State private var saved = false
    @State private var tab: ScanTab = .overview
    @State private var showHistory = false
    @State private var shareItems: ShareItems?

    private struct ShareItems: Identifiable { let id = UUID(); let items: [Any] }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HeroCard(export: export, scanning: nfc.scanning, status: nfc.status, saved: saved)
                    if let err = nfc.errorText { ErrorBanner(text: err) }
                    if let e = export {
                        Picker("Section", selection: $tab) {
                            ForEach(tabs(for: e)) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        switch tabs(for: e).contains(tab) ? tab : .overview {
                        case .overview: overview(e)
                        case .readings: readings(e)
                        case .technical: technical(e)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .animation(reduceMotion ? nil : .default, value: tab)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Libre Export")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: {
                        Label("Saved scans", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { settingsMenu }
            }
            .safeAreaInset(edge: .bottom) {
                ScanButton(scanning: nfc.scanning) { nfc.deepScan = deepScan; nfc.scan() }
            }
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(store: store, openID: export?.result.scannedAt) { scan in
                export = makeExport(scan); saved = true; tab = .overview; nfc.errorText = nil; showHistory = false
            }
        }
        .sheet(item: $shareItems) { ShareSheet(items: $0.items) }
        .onChange(of: nfc.result?.scannedAt) { _, _ in
            // the scan on screen stays until a new one arrives (a cancelled rescan keeps it)
            guard let r = nfc.result else { return }
            export = makeExport(r); saved = false; tab = .overview
            store.add(r)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        .onChange(of: nfc.errorText) { _, text in
            if text != nil { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        }
        .onChange(of: store.scans.count) { _, _ in
            // a deleted scan doesn't stay on screen
            if let id = export?.result.scannedAt, !store.scans.contains(where: { $0.scannedAt == id }) {
                export = nil; saved = false
            }
        }
        #if DEBUG
        .onAppear {
            if DemoScan.isOn, nfc.result == nil { export = makeExport(DemoScan.result()); saved = DemoScan.saved; tab = DemoScan.tab ?? .overview }
        }
        #endif
        .task {
            removeExportFiles()   // share files left from an earlier run
            // after a restart, show the newest saved scan (marked as saved) instead of an empty screen
            #if DEBUG
            if DemoScan.isOn { return }
            #endif
            if export == nil, let newest = store.scans.first { export = makeExport(newest); saved = true }
        }
    }

    private var settingsMenu: some View {
        Menu {
            Picker("Glucose unit", selection: $unit) {
                ForEach(GlucoseUnit.allCases) { Text($0.label).tag($0) }
            }
            Toggle(isOn: $deepScan) {
                Label("Read all memory (slower)", systemImage: "memorychip")
            }
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
    }

    // MARK: - Tabs

    /// Readings only when there are any (not for Gen2, Libre 3 or a memory that didn't parse).
    private func tabs(for e: Export) -> [ScanTab] {
        e.hasReadings ? ScanTab.allCases : [.overview, .technical]
    }

    @ViewBuilder private func overview(_ e: Export) -> some View {
        if let p = e.parsed { CRCRow(p: p) }
        if let notice = e.notice { InfoCard(text: notice) }
        if e.trustworthy, let p = e.parsed { ChartCard(p: p, scannedAt: e.result.scannedAt) }
        PatchInfoCard(e: e)
        if e.trustworthy, let p = e.parsed { StatusCard(p: p, scannedAt: e.result.scannedAt, saved: saved) }
        ShareCard(e: e) { shareItems = ShareItems(items: $0) }
            .id(e.result.scannedAt)   // "Copied" doesn't carry over to another scan
    }

    @ViewBuilder private func readings(_ e: Export) -> some View {
        if let p = e.parsed {
            if !e.trustworthy { InfoCard(text: "These come from a memory whose CRCs don't match: likely garbage.") }
            TrendCard(trend: p.trend, minutesSinceStart: p.minutesSinceStart)
            HistoryTableCard(history: p.history, scannedAt: e.result.scannedAt, minutesSinceStart: p.minutesSinceStart)
        } else {
            InfoCard(text: e.notice ?? "No readings in this scan.")
        }
    }

    @ViewBuilder private func technical(_ e: Export) -> some View {
        if let p = e.parsed { FRAMCard(e: e, p: p) }
        TagCard(uid: e.result.uid, tag: e.result.tag)
        RawCard(e: e)
    }
}
