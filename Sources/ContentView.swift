//  ContentView.swift — scan, verify on-device, share a base64 export. Polished SwiftUI.
import SwiftUI
import UIKit

// MARK: - Export payload

struct Export {
    let base64: String
    let parsed: ParsedSensor?
    let generation: Int
    let result: ScanResult
    let patch: PatchInfoDecoded
    let serial: String
    let framDecrypted: [UInt8]
}

func makeExport(_ r: ScanResult) -> Export {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    let iso = ISO8601DateFormatter()
    var parsed: ParsedSensor?
    var decrypted: [UInt8] = []
    if !r.framEncrypted.isEmpty,
       let dec = Libre2FRAM.decryptFRAM(id: r.uid, info: r.patchInfo, data: r.framEncrypted) {
        decrypted = dec
        parsed = SensorParse.parse(uid: r.uid, patchInfo: r.patchInfo, fram: dec)
    }
    let patch = PatchInfoDecoded(raw: r.patchInfo)
    func records(_ rs: [Record]) -> [[String: Any]] {
        rs.map {
            var d: [String: Any] = ["minute": -$0.minuteOffset, "raw_glucose": $0.rawGlucose,
                                    "raw_temperature": $0.rawTemperature,
                                    "raw_temperature_adjustment": $0.rawTemperatureAdjustment]
            if let t = $0.temperature { d["temperature_c"] = (t * 100).rounded() / 100 }
            if let g = $0.glucose { d["glucose_mgdl"] = (g * 10).rounded() / 10 }
            return d
        }
    }
    var tag: [String: Any] = ["ic_manufacturer_code": r.tag.icManufacturerCode,
                              "ic_serial_number": hex(r.tag.icSerialNumber)]
    if let si = r.tag.systemInfo {
        tag["dsfid"] = si.dsfid; tag["afi"] = si.afi; tag["block_size"] = si.blockSize
        tag["total_blocks"] = si.totalBlocks; tag["ic_reference"] = si.icReference
    }
    if let e = r.tag.systemInfoError { tag["system_info_error"] = e }
    var patchDecoded: [String: Any] = ["sensor_type": patch.sensorType, "generation": patch.generation]
    patchDecoded["family"] = patch.family
    patchDecoded["security"] = patch.securityNibble
    patchDecoded["region_code"] = patch.regionCode
    patchDecoded["crypto_word"] = patch.cryptoWord

    var payload: [String: Any] = [
        "format": "libre2-fram-export-v1",
        "scanned_at": iso.string(from: r.scannedAt),
        "uid": hex(r.uid), "patch_info": hex(r.patchInfo),
        "patch_info_decoded": patchDecoded,
        "serial": SensorParse.serialNumber(uid: r.uid, patchInfo: r.patchInfo),
        "tag": tag,
        "generation": Libre2FRAM.securityGeneration(r.patchInfo),
        "fram_encrypted_hex": hex(r.framEncrypted), "fram_decrypted_hex": hex(decrypted),
        "minutes_since_start": parsed?.minutesSinceStart ?? -1,
        "calibration": parsed.map { ["i1": $0.i1, "i2": $0.i2, "i3": $0.i3, "i4": $0.i4, "i5": $0.i5, "i6": $0.i6] } ?? [:],
        "trend_records": records(parsed?.trend ?? []),
        "history_records": records(parsed?.history ?? []),
    ]
    if let p = parsed {
        payload["sensor_state"] = p.state
        payload["max_minutes_wear"] = p.maxMinutesWear
        payload["next_trend_block"] = p.nextTrendBlock
        payload["next_history_block"] = p.nextHistoryBlock
        payload["fram_region"] = p.regionByte
        payload["started_at"] = iso.string(from: r.scannedAt.addingTimeInterval(-60 * Double(p.minutesSinceStart)))
        payload["ends_at"] = iso.string(from: r.scannedAt.addingTimeInterval(60 * Double(p.minutesLeft)))
        payload["crc"] = ["header": ["stored": p.headerCRC.stored, "computed": p.headerCRC.computed],
                          "body": ["stored": p.bodyCRC.stored, "computed": p.bodyCRC.computed],
                          "footer": ["stored": p.footerCRC.stored, "computed": p.footerCRC.computed]]
    }
    let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    return Export(base64: json.base64EncodedString(), parsed: parsed, generation: patch.generation,
                  result: r, patch: patch,
                  serial: SensorParse.serialNumber(uid: r.uid, patchInfo: r.patchInfo),
                  framDecrypted: decrypted)
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var nfc = NFCReader()
    @State private var showShare = false
    @State private var export: Export?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HeroCard(export: export, scanning: nfc.scanning, status: nfc.status)
                    if let err = nfc.errorText { ErrorBanner(text: err) }
                    if let e = export {
                        if let p = e.parsed {
                            CRCRow(p: p)
                            DetailCard(p: p, scannedAt: e.result.scannedAt)
                            TrendCard(trend: p.trend)
                            HistoryCard(history: p.history, scannedAt: e.result.scannedAt)
                        } else {
                            InfoCard(text: e.generation == 2
                                ? "Gen2 sensor: captured UID + patch info. The FRAM needs the authenticated read, so no values here — the export still carries the identity."
                                : "Captured, but the FRAM did not decrypt/parse. The raw bytes are in the export for offline analysis.")
                        }
                        PatchInfoCard(patch: e.patch, serial: e.serial)
                        TagCard(uid: e.result.uid, tag: e.result.tag)
                        RawCard(e: e)
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
        .onChange(of: nfc.scanning) { _, scanning in if scanning { export = nil } }
        .onChange(of: nfc.result?.scannedAt) { _, _ in export = nfc.result.map(makeExport) }
        #if DEBUG
        .onAppear { if DemoScan.isOn, nfc.result == nil { export = makeExport(DemoScan.result()) } }
        #endif
    }
}

// MARK: - Hero

private struct HeroCard: View {
    let export: Export?; let scanning: Bool; let status: String

    var body: some View {
        VStack(spacing: 10) {
            if let e = export, let p = e.parsed, let g = p.trend.first?.glucose {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(String(format: "%.0f", g)).font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(glucoseColor(g))
                    Text("mg/dL").font(.title3.weight(.medium)).foregroundStyle(.secondary)
                    Image(systemName: arrow(for: p.trend)).font(.title).foregroundStyle(glucoseColor(g))
                }
                Text("\(p.serial) · \(p.ageHuman) · Gen \(p.generation)")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else if let e = export, !scanning {
                Image(systemName: "sensor.tag.radiowaves.forward.fill")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                Text(e.serial).font(.title2.weight(.semibold).monospaced())
                Text("\(e.patch.sensorType) · \(e.patch.generationLabel)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let p = e.parsed {
                    Text("\(SensorLabels.state(p.state)) · \(p.ageHuman)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
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
            chip("Header", p.headerCRC.ok); chip("Body", p.bodyCRC.ok); chip("Footer", p.footerCRC.ok)
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
    let p: ParsedSensor; let scannedAt: Date
    var body: some View {
        Card(title: "Sensor (FRAM)", icon: "sensor.tag.radiowaves.forward") {
            KV("Serial", p.serial)
            KV("State", "\(SensorLabels.state(p.state)) (\(Hex.byte(p.state)))")
            KV("Age", "\(p.ageHuman)  ·  \(p.minutesSinceStart) min")
            KV("Wear time", "\(ParsedSensor.human(p.maxMinutesWear))  ·  \(p.maxMinutesWear) min")
            KV("Left", "\(p.leftHuman)  ·  \(p.minutesLeft) min")
            KV("Started", dateTime(scannedAt.addingTimeInterval(-60 * Double(p.minutesSinceStart))))
            KV("Ends", dateTime(scannedAt.addingTimeInterval(60 * Double(p.minutesLeft))))
            KV("Scanned", dateTime(scannedAt))
            KV("Region", "\(SensorLabels.region(p.regionByte)) (\(Hex.byte(p.regionByte)), byte 323)")
            KV("Ring index", "trend \(p.nextTrendBlock) · history \(p.nextHistoryBlock)")
            Divider().padding(.vertical, 2)
            KV("i1 · i2", "\(p.i1) · \(p.i2)")
            KV("i3 · i4", "\(Int(p.i3)) · \(Int(p.i4))")
            KV("i5 · i6", "\(Int(p.i5)) · \(Int(p.i6))")
            Divider().padding(.vertical, 2)
            KV("Header CRC", crc(p.headerCRC))
            KV("Body CRC", crc(p.bodyCRC))
            KV("Footer CRC", crc(p.footerCRC))
        }
    }
    private func crc(_ c: CRCCheck) -> String {
        c.ok ? "\(Hex.word(Int(c.stored))) ✓" : "\(Hex.word(Int(c.stored))) ≠ \(Hex.word(Int(c.computed)))"
    }
}

private struct PatchInfoCard: View {
    let patch: PatchInfoDecoded; let serial: String
    var body: some View {
        Card(title: "Patch info", icon: "info.square") {
            KV("Raw", patch.raw.isEmpty ? "–" : Hex.string(patch.raw, separator: " "))
            KV("Bytes", "\(patch.raw.count)")
            KV("Type", patch.sensorType)
            KV("Generation", patch.generationLabel)
            if let f = patch.family, let sec = patch.securityNibble {
                KV("Family", "\(f) · security \(sec)")
            }
            if let r = patch.regionCode { KV("Region", "\(SensorLabels.region(r)) (\(Hex.byte(r)))") }
            if let w = patch.cryptoWord { KV("Bytes 4–5", Hex.word(w)) }
            KV("Serial", serial)
        }
    }
}

private struct TagCard: View {
    let uid: [UInt8]; let tag: TagInfo
    var body: some View {
        Card(title: "NFC tag", icon: "wave.3.right") {
            KV("UID", Hex.string(uid.reversed(), separator: ":"))
            KV("Maker", "\(SensorLabels.icManufacturer(tag.icManufacturerCode)) (\(Hex.byte(tag.icManufacturerCode)))")
            KV("IC serial", Hex.string(tag.icSerialNumber))
            if let si = tag.systemInfo {
                KV("Memory", "\(si.totalBlocks) blocks × \(si.blockSize) bytes")
                KV("IC ref", opt(si.icReference))
                KV("DSFID · AFI", "\(opt(si.dsfid)) · \(opt(si.afi))")
            } else if let err = tag.systemInfoError {
                KV("System info", "not answered: \(err)")
            }
        }
    }
    private func opt(_ v: Int) -> String { v < 0 ? "–" : Hex.byte(v) }
}

private struct RawCard: View {
    let e: Export
    @State private var open = false
    var body: some View {
        Card(title: "Raw bytes", icon: "memorychip") {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    block("FRAM, as read", e.result.framEncrypted)
                    if !e.framDecrypted.isEmpty { block("FRAM, decrypted", e.framDecrypted) }
                }.padding(.top, 6)
            } label: {
                Text(e.result.framEncrypted.isEmpty ? "No FRAM read" : "\(e.result.framEncrypted.count) bytes FRAM")
                    .font(.subheadline)
            }.disabled(e.result.framEncrypted.isEmpty)
        }
    }
    private func block(_ title: String, _ b: [UInt8]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            // 8 bytes per row = one NFC block; row label = block number
            Text(stride(from: 0, to: b.count, by: 8).map {
                String(format: "%02d  ", $0 / 8) + Hex.string(Array(b[$0..<min($0 + 8, b.count)]), separator: " ")
            }.joined(separator: "\n"))
            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
    }
}

private struct KV: View {
    let k: String; let v: String
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
            Text(v).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
            Spacer(minLength: 0)
        }.font(.subheadline)
    }
}

private func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

private func tempText(_ t: Double?) -> String { t.map { String(format: "%.1f", $0) } ?? "–" }

private struct TrendCard: View {
    let trend: [Record]
    var body: some View {
        Card(title: "Trend · last 16 min", icon: "waveform.path.ecg") {
            Sparkline(values: trend.reversed().compactMap { $0.glucose }).frame(height: 56)
            Divider().padding(.vertical, 2)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("min").gridColumnAlignment(.leading); Text("rawG"); Text("rawT"); Text("adj"); Text("°C"); Text("mg/dL")
                }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(trend.indices, id: \.self) { i in
                    let r = trend[i]
                    GridRow {
                        Text("\(-r.minuteOffset)").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                        Text("\(r.rawGlucose)"); Text("\(r.rawTemperature)"); Text("\(r.rawTemperatureAdjustment)")
                        Text(tempText(r.temperature))
                        Text(r.glucose.map { String(format: "%.0f", $0) } ?? "–").fontWeight(.medium)
                    }
                }
            }.font(.system(.caption, design: .monospaced))
        }
    }
}

private struct HistoryCard: View {
    let history: [Record]; let scannedAt: Date
    var body: some View {
        Card(title: "History · last 8 h, every 15 min", icon: "chart.xyaxis.line") {
            Sparkline(values: history.reversed().compactMap { $0.glucose }).frame(height: 56)
            Divider().padding(.vertical, 2)
            Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow {
                    Text("time").gridColumnAlignment(.leading); Text("min"); Text("rawG"); Text("°C"); Text("mg/dL")
                }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(history.indices, id: \.self) { i in
                    let r = history[i]
                    GridRow {
                        Text(scannedAt.addingTimeInterval(-60 * Double(r.minuteOffset)).formatted(date: .omitted, time: .shortened))
                            .gridColumnAlignment(.leading).foregroundStyle(.secondary)
                        Text("\(-r.minuteOffset)").foregroundStyle(.secondary)
                        Text("\(r.rawGlucose)"); Text(tempText(r.temperature))
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
