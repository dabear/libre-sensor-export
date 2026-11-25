//  ContentView.swift — scan, verify on-device, share a base64 export. Polished SwiftUI.
import SwiftUI
import UIKit

// MARK: - Export payload

struct Export { let base64: String; let parsed: ParsedSensor?; let generation: Int }

func makeExport(_ r: ScanResult) -> Export {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    var parsed: ParsedSensor?
    var decrypted: [UInt8] = []
    if !r.framEncrypted.isEmpty,
       let dec = Libre2FRAM.decryptFRAM(id: r.uid, info: r.patchInfo, data: r.framEncrypted) {
        decrypted = dec
        parsed = SensorParse.parse(uid: r.uid, patchInfo: r.patchInfo, fram: dec)
    }
    let records = (parsed?.trend ?? []).map {
        ["minute": -$0.minuteOffset, "raw_glucose": $0.rawGlucose,
         "raw_temperature": $0.rawTemperature, "raw_temperature_adjustment": $0.rawTemperatureAdjustment]
    }
    let payload: [String: Any] = [
        "format": "libre2-fram-export-v1",
        "scanned_at": ISO8601DateFormatter().string(from: Date()),
        "uid": hex(r.uid), "patch_info": hex(r.patchInfo),
        "generation": Libre2FRAM.securityGeneration(r.patchInfo),
        "fram_encrypted_hex": hex(r.framEncrypted), "fram_decrypted_hex": hex(decrypted),
        "minutes_since_start": parsed?.minutesSinceStart ?? -1,
        "calibration": parsed.map { ["i1": $0.i1, "i2": $0.i2, "i3": $0.i3, "i4": $0.i4, "i5": $0.i5, "i6": $0.i6] } ?? [:],
        "trend_records": records,
    ]
    let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    return Export(base64: json.base64EncodedString(), parsed: parsed,
                  generation: Libre2FRAM.securityGeneration(r.patchInfo))
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var nfc = NFCReader()
    @State private var showShare = false

    private var export: Export? { nfc.result.map(makeExport) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HeroCard(parsed: export?.parsed, generation: export?.generation,
                             scanning: nfc.scanning, status: nfc.status)
                    if let err = nfc.errorText { ErrorBanner(text: err) }
                    if let e = export {
                        if let p = e.parsed {
                            CRCRow(p: p)
                            DetailCard(p: p)
                            TrendCard(trend: p.trend)
                        } else {
                            InfoCard(text: e.generation == 2
                                ? "Gen2 sensor: captured UID + patch info. The FRAM needs the authenticated read, so no values here — the export still carries the identity."
                                : "Captured, but the FRAM did not decrypt/parse. The raw bytes are in the export for offline analysis.")
                        }
                        ExportCard(base64: e.base64, showShare: $showShare)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Libre Export")
            .safeAreaInset(edge: .bottom) { ScanButton(scanning: nfc.scanning, action: nfc.scan) }
        }
        .sheet(isPresented: $showShare) { if let b = export?.base64 { ShareSheet(items: [b]) } }
    }
}

// MARK: - Hero

private struct HeroCard: View {
    let parsed: ParsedSensor?; let generation: Int?; let scanning: Bool; let status: String

    var body: some View {
        VStack(spacing: 10) {
            if let p = parsed, let g = p.trend.first?.glucose {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.0f", g)).font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(glucoseColor(g))
                    Text("mg/dL").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    Image(systemName: arrow(for: p.trend)).font(.title).foregroundStyle(glucoseColor(g))
                }
                Text("\(p.serial) · \(p.ageHuman) · Gen \(p.generation)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                Image(systemName: scanning ? "dot.radiowaves.left.and.right" : "wave.3.right.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: scanning)
                Text(scanning ? "Scanning…" : "Ready to scan")
                    .font(.title2.weight(.semibold))
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    private func arrow(for trend: [Record]) -> String {
        let vals = trend.prefix(6).compactMap { $0.glucose }
        guard vals.count >= 2 else { return "arrow.right" }
        let slope = (vals.first! - vals.last!) / Double(vals.count - 1)  // per minute, newest-first
        switch slope {
        case ..<(-2): return "arrow.down"
        case -2 ..< -1: return "arrow.down.right"
        case -1...1: return "arrow.right"
        case 1...2: return "arrow.up.right"
        default: return "arrow.up"
        }
    }
}

private func glucoseColor(_ g: Double) -> Color {
    switch g { case ..<70: return .red; case 70..<180: return .green; case 180..<250: return .orange; default: return .red }
}

// MARK: - Cards

private struct CRCRow: View {
    let p: ParsedSensor
    var body: some View {
        HStack(spacing: 10) {
            chip("Header", p.headerCRC); chip("Body", p.bodyCRC); chip("Footer", p.footerCRC)
        }
    }
    private func chip(_ t: String, _ ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
            Text(t).font(.caption.weight(.medium))
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill((ok ? Color.green : .red).opacity(0.15)))
        .foregroundStyle(ok ? .green : .red)
    }
}

private struct DetailCard: View {
    let p: ParsedSensor
    var body: some View {
        Card(title: "Sensor", icon: "sensor.tag.radiowaves.forward") {
            row("Serial", p.serial)
            row("Age", "\(p.ageHuman)  ·  \(p.minutesSinceStart) / \(p.maxMinutesWear) min")
            row("Calibration", "i2 \(p.i2) · i3 \(Int(p.i3)) · i4 \(Int(p.i4)) · i6 \(Int(p.i6))")
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(v).font(.system(.subheadline, design: .monospaced)); Spacer(minLength: 0)
        }.font(.subheadline)
    }
}

private struct TrendCard: View {
    let trend: [Record]
    var body: some View {
        Card(title: "Trend · last 16 min", icon: "waveform.path.ecg") {
            Sparkline(values: trend.reversed().compactMap { $0.glucose }).frame(height: 56)
            Divider().padding(.vertical, 2)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("min").gridColumnAlignment(.leading); Text("rawG"); Text("rawT"); Text("adj"); Text("mg/dL")
                }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(trend.indices, id: \.self) { i in
                    let r = trend[i]
                    GridRow {
                        Text("\(-r.minuteOffset)").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                        Text("\(r.rawGlucose)"); Text("\(r.rawTemperature)"); Text("\(r.rawTemperatureAdjustment)")
                        Text(r.glucose.map { String(format: "%.0f", $0) } ?? "–").fontWeight(.medium)
                    }
                }
            }.font(.system(.caption, design: .monospaced))
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            if values.count > 1 {
                let lo = values.min()!, hi = values.max()!, span = max(hi - lo, 1)
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(values.count - 1),
                            y: geo.size.height * (1 - CGFloat((v - lo) / span)))
                }
                Path { p in p.addLines(pts) }
                    .stroke(.tint, style: .init(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

private struct ExportCard: View {
    let base64: String; @Binding var showShare: Bool
    @State private var copied = false
    var body: some View {
        Card(title: "Export · base64", icon: "square.and.arrow.up.on.square") {
            Text(base64).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(4).truncationMode(.middle).textSelection(.enabled)
            HStack(spacing: 10) {
                Button { UIPasteboard.general.string = base64; copied = true } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { showShare = true } label: {
                    Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent)
            }.controlSize(.large)
        }
    }
}

private struct InfoCard: View { let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct ErrorBanner: View { let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.red.opacity(0.12)))
            .foregroundStyle(.red)
    }
}

private struct Card<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }
}

private struct ScanButton: View {
    let scanning: Bool; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(scanning ? "Scanning…" : "Scan sensor", systemImage: "wave.3.right")
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 16)
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(scanning)
        .padding(.horizontal, 16).padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
