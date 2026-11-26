//  Cards.swift — the building blocks of the scan screen.
import SwiftUI
import UIKit

// MARK: - Hero

struct HeroCard: View {
    let export: Export?; let scanning: Bool; let status: String
    /// Opened from saved scans (or restored at launch), not just scanned.
    var saved = false
    @AppStorage("glucoseUnit") private var unit: GlucoseUnit = .regionDefault
    @ScaledMetric(relativeTo: .largeTitle) private var valueSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 8) {
            if let e = export {
                if saved {
                    Label("Saved scan · \(dateTime(e.result.scannedAt))", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(Color(.tertiarySystemFill)))
                }
                if e.trustworthy, let p = e.parsed {
                    reading(e, p)
                } else {
                    Image(systemName: e.parsed == nil ? "sensor.tag.radiowaves.forward.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 48)).foregroundStyle(e.parsed == nil ? Color.accentColor : .orange)
                        .accessibilityHidden(true)
                    Text(e.serial == "–" ? e.patch.summary : e.serial).font(.title2.weight(.semibold).monospaced())
                    if e.serial != "–" { Text(e.patch.summary).font(.subheadline).foregroundStyle(.secondary) }
                    if e.parsed != nil {
                        Text("CRCs don't match: no reading shown").font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                    }
                    ScannedAgo(date: e.result.scannedAt).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: scanning ? "dot.radiowaves.left.and.right" : "wave.3.right.circle.fill")
                    .font(.system(size: 54)).foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: scanning)
                    .accessibilityHidden(true)
                Text(scanning ? "Scanning…" : "Ready to scan")
                    .font(.title2.weight(.semibold))
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 24).fill(Color(.secondarySystemGroupedBackground)))
    }

    @ViewBuilder private func reading(_ e: Export, _ p: ParsedSensor) -> some View {
        let newest = p.trend.first
        // A sensor that has ended (expired, shut down, failed) keeps its last stored values.
        let ended = p.state >= 4
        if let g = newest?.glucose {
            let arrow = trendArrow(p.trendRate)
            let color = ended ? Color.secondary : glucoseColor(g)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(unit.format(g)).font(.system(size: valueSize, weight: .bold, design: .rounded))
                    .foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.5)
                Text(unit.label).font(.title3.weight(.medium)).foregroundStyle(.secondary)
                if !ended { Image(systemName: arrow.symbol).font(.title).foregroundStyle(color) }
                if let bits = newest?.errorBits, bits != 0 {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title3).foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(unit.format(g)) \(unit.spoken), \(ended ? "last stored reading" : arrow.words)\(newest?.errorBits ?? 0 != 0 ? ", with quality flags" : "")")
            if ended {
                Text("Sensor \(SensorLabels.state(p.state).lowercased()): last stored reading")
                    .font(.footnote.weight(.medium)).foregroundStyle(.secondary)
            } else {
                ScannedAgo(date: e.result.scannedAt,
                           prefix: p.trendRate.map { "\(unit.formatRate($0)) \(unit.label)/min · " } ?? "")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            Image(systemName: "drop.degreesign.slash").font(.system(size: 44)).foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("No current reading").font(.title2.weight(.semibold))
            ScannedAgo(date: e.result.scannedAt).font(.footnote).foregroundStyle(.secondary)
        }
        Text("\(p.serial) · \(p.ageHuman)").font(.subheadline).foregroundStyle(.secondary)
        Text(e.patch.summary).font(.subheadline).foregroundStyle(.secondary)
        if let w = p.warmupMinutesLeft {
            Label("Warming up: ready in \(w) min\(saved ? " (at scan time)" : "")", systemImage: "hourglass")
                .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
        } else if let x = p.expiredMinutesAgo {
            Label("Expired \(ParsedSensor.human(x)) before the scan", systemImage: "clock.badge.xmark")
                .font(.subheadline.weight(.medium)).foregroundStyle(.red)
        }
    }
}

/// "scanned 3 minutes ago", kept current while the screen is open.
struct ScannedAgo: View {
    let date: Date
    var prefix = ""
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            // one Text, so it wraps as a sentence at large text sizes
            Text(verbatim: prefix) + Text("scanned \(date, format: .relative(presentation: .named, unitsStyle: .wide))")
        }
    }
}

// MARK: - Overview

struct CRCRow: View {
    let p: ParsedSensor
    var body: some View {
        HStack(spacing: 10) {
            chip("Header", p.headerCRC.ok); chip("Body", p.bodyCRC.ok); chip("Footer", p.footerCRC.ok)
        }
    }
    private func chip(_ t: String, _ ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.seal.fill" : "xmark.seal.fill")
            Text(t).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8).frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill((ok ? Color.green : .red).opacity(0.15)))
        .foregroundStyle(ok ? .green : .red)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(t) CRC \(ok ? "matches" : "doesn't match")")
    }
}

struct ChartCard: View {
    let p: ParsedSensor; let scannedAt: Date
    var body: some View {
        let points = glucosePoints(p, scannedAt: scannedAt)
        Card(title: "Last 8 hours", icon: "chart.xyaxis.line") {
            if points.count > 1 {
                GlucoseChart(points: points)
                if points.contains(where: \.flagged) {
                    Label("Triangles: readings with quality flags (see Readings).", systemImage: "triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("No readings to chart yet.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusCard: View {
    let p: ParsedSensor; let scannedAt: Date
    var saved = false
    var body: some View {
        Card(title: saved ? "Sensor, at scan time" : "Sensor", icon: "sensor.tag.radiowaves.forward") {
            KV("State", "\(SensorLabels.state(p.state)) (\(Hex.byte(p.state)))")
            if let w = p.warmupMinutesLeft { KV("Warm-up", "ready in \(w) min") }
            KV("Age", "\(p.ageHuman)  ·  \(p.minutesSinceStart) min")
            KV("Wear time", "\(ParsedSensor.human(p.maxMinutesWear))  ·  \(p.maxMinutesWear) min")
            if let x = p.expiredMinutesAgo { KV("Expired", "\(ParsedSensor.human(x)) ago") }
            else { KV("Left", "\(p.leftHuman)  ·  \(p.minutesLeft) min") }
            KV("Started", dateTime(scannedAt.addingTimeInterval(-60 * Double(p.minutesSinceStart))))
            KV("Ends", dateTime(scannedAt.addingTimeInterval(60 * Double(p.maxMinutesWear - p.minutesSinceStart))))
            KV("Scanned", dateTime(scannedAt))
        }
    }
}

struct PatchInfoCard: View {
    let e: Export
    var body: some View {
        let patch = e.patch
        Card(title: "Patch info", icon: "info.square") {
            KV("Raw", patch.raw.isEmpty ? "–" : Hex.string(patch.raw, separator: " "))
            if let err = e.result.patchInfoError { KV("Not answered", err) }
            if let b0 = patch.raw.first { KV("Byte 0", Hex.byte(Int(b0))) }
            if !patch.isLibre3 {
                if let f = patch.family { KV("Family", "\(f) (\(patch.familyName))") }
                if let sec = patch.securityNibble { KV("Security ver", "\(sec) → \(patch.generationShort)") }
                if let r = patch.regionCode { KV("Region", "\(patch.regionName) (\(Hex.byte(r)))") }
            }
            KV("LT type", "\(patch.sensorType) (main)")
            KV("", "\(patch.sensorTypePR67) (PR #67)")
            KV("Gen1 crypto", e.cryptoSummary)
            Divider().padding(.vertical, 2)
            if !patch.isLibre3, let w = patch.cryptoWord { KV("Bytes 4–5", Hex.word(w)) }
            KV("Serial", e.serial)
        }
    }
}

struct ShareCard: View {
    let e: Export; let share: ([Any]) -> Void
    @State private var copied: String?
    var body: some View {
        Card(title: "Share", icon: "square.and.arrow.up.on.square") {
            Button { copy(makeReport(e), "report") } label: {
                Label(copied == "report" ? "Copied" : "Copy report", systemImage: copied == "report" ? "checkmark" : "doc.text")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            HStack(spacing: 10) {
                Button { if let url = exportFile(e) { share([url]) } } label: {
                    Label("JSON file", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
                Button { copy(e.base64, "base64") } label: {
                    Label(copied == "base64" ? "Copied" : "Base64", systemImage: copied == "base64" ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }
            Text("The report leaves out the UID, serial, readings and patch info from byte 4, so it's safe to post. The JSON file and base64 contain everything, including the sensor's identity and your glucose data.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.large)
    }
    private func copy(_ text: String, _ what: String) {
        UIPasteboard.general.string = text
        copied = what
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

// MARK: - Readings

struct TrendCard: View {
    let trend: [Record]
    var minutesSinceStart = Int.max
    @AppStorage("glucoseUnit") private var unit: GlucoseUnit = .regionDefault
    var body: some View {
        Card(title: "Trend · last 16 min, every minute", icon: "waveform.path.ecg") {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("min").gridColumnAlignment(.leading); Text("rawG"); Text("rawT"); Text("adj")
                        Text("°C"); Text(unit.label); Text("")
                    }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    let rows = trend.filter { $0.minuteOffset <= minutesSinceStart }
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        GridRow {
                            Text(verbatim: "\(-r.minuteOffset)").gridColumnAlignment(.leading).foregroundStyle(.secondary)
                                .accessibilityLabel(rowLabel(r, unit: unit))
                            Group {
                                Text(verbatim: "\(r.rawGlucose)"); Text(verbatim: "\(r.rawTemperature)"); Text(verbatim: "\(r.rawTemperatureAdjustment)")
                                Text(tempText(r.temperature))
                                Text(r.glucose.map(unit.format) ?? "–").fontWeight(.medium)
                                FlagMark(bits: r.errorBits)
                            }.accessibilityHidden(true)
                        }
                    }
                }.font(.system(.caption, design: .monospaced))
            }
            FlagLegend(records: trend)
        }
    }
}

struct HistoryTableCard: View {
    let history: [Record]; let scannedAt: Date
    var minutesSinceStart = Int.max
    @AppStorage("glucoseUnit") private var unit: GlucoseUnit = .regionDefault
    var body: some View {
        Card(title: "History · last 8 h, every 15 min", icon: "clock") {
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        Text("time").gridColumnAlignment(.leading); Text("min"); Text("rawG"); Text("°C")
                        Text(unit.label); Text("")
                    }.font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    // records from before the sensor started are empty slots
                    let rows = history.filter { $0.minuteOffset <= minutesSinceStart }
                    ForEach(rows.indices, id: \.self) { i in
                        let r = rows[i]
                        GridRow {
                            Text(scannedAt.addingTimeInterval(-60 * Double(r.minuteOffset)).formatted(date: .omitted, time: .shortened))
                                .gridColumnAlignment(.leading).foregroundStyle(.secondary)
                                .accessibilityLabel(rowLabel(r, unit: unit))
                            Group {
                                Text(verbatim: "\(-r.minuteOffset)").foregroundStyle(.secondary)
                                Text(verbatim: "\(r.rawGlucose)"); Text(tempText(r.temperature))
                                Text(r.glucose.map(unit.format) ?? "–").fontWeight(.medium)
                                FlagMark(bits: r.errorBits)
                            }.accessibilityHidden(true)
                        }
                    }
                }.font(.system(.caption, design: .monospaced))
            }
            FlagLegend(records: history)
        }
    }
}

/// One spoken sentence per table row, instead of seven separate cells.
private func rowLabel(_ r: Record, unit: GlucoseUnit) -> String {
    var parts = [r.minuteOffset == 0 ? "now" : "\(r.minuteOffset) minutes ago"]
    parts.append(r.glucose.map { "\(unit.format($0)) \(unit.spoken)" } ?? "no glucose value")
    if let t = r.temperature { parts.append("\(tempText(t)) degrees") }
    parts.append("raw \(r.rawGlucose)")
    if r.errorBits != 0 { parts.append("quality flags: \(SensorLabels.measurementErrors(r.errorBits).joined(separator: ", "))") }
    return parts.joined(separator: ", ")
}

/// A warning triangle on a reading with quality flags.
private struct FlagMark: View {
    let bits: Int
    var body: some View {
        if bits != 0 {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .accessibilityLabel("Quality flags: \(SensorLabels.measurementErrors(bits).joined(separator: ", "))")
        } else {
            Text("")
        }
    }
}

/// Which flags the flagged readings carry.
private struct FlagLegend: View {
    let records: [Record]
    var body: some View {
        let flagged = records.filter { $0.errorBits != 0 }
        if !flagged.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text("Quality flags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(flagged.indices, id: \.self) { i in
                    let r = flagged[i]
                    Text(verbatim: "\(-r.minuteOffset) min: \(SensorLabels.measurementErrors(r.errorBits).joined(separator: ", ")) (\(Hex.word(r.errorBits)))")
                        .font(.caption.monospaced())
                }
            }
        }
    }
}

// MARK: - Technical

struct FRAMCard: View {
    let e: Export; let p: ParsedSensor
    var body: some View {
        Card(title: "Memory (FRAM)", icon: "cpu") {
            KV("Encryption", e.encryption.label)
            KV("FRAM region", "\(SensorLabels.region(p.regionByte)) (\(Hex.byte(p.regionByte)), byte 323)")
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

struct TagCard: View {
    let uid: [UInt8]; let tag: TagInfo
    var body: some View {
        Card(title: "NFC chip", icon: "wave.3.right") {
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
            Divider().padding(.vertical, 2)
            if let status = tag.blockSecurity {
                let ranges = runs(status)
                ForEach(Array(ranges.prefix(8).enumerated()), id: \.offset) { i, run in
                    KV(i == 0 ? "Lock status" : "",
                       "\(run.first == run.last ? "block \(run.first)" : "blocks \(run.first)–\(run.last)"): \(run.value & 1 == 1 ? "locked" : "open")\(run.value > 1 ? " (\(Hex.byte(run.value)))" : "")")
                }
                if ranges.count > 8 { KV("", "… \(ranges.count - 8) more ranges in the export") }
            }
            if let err = tag.blockSecurityError { KV(tag.blockSecurity == nil ? "Lock status" : "", "not answered \(err)") }
            if let note = tag.extraMemoryNote { KV("Beyond FRAM", note) }
        }
    }
    private func opt(_ v: Int) -> String { v < 0 ? "–" : Hex.byte(v) }
}

struct RawCard: View {
    let e: Export
    @State private var open = false
    @State private var copied: String?
    var body: some View {
        let read = e.result.framEncrypted, extra = e.result.tag.extraMemory ?? []
        Card(title: "Raw bytes", icon: "memorychip") {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: 10) {
                    block(e.encryption == .none ? "FRAM (not encrypted)" : "FRAM, as read", read, from: 0)
                    if e.encryption != .none, !e.framDecrypted.isEmpty { block("FRAM, decrypted", e.framDecrypted, from: 0) }
                    if !extra.isEmpty { block("Beyond FRAM", extra, from: 43) }
                }.padding(.top, 6)
            } label: {
                Text(read.isEmpty ? "No memory read" : "\(read.count + extra.count) bytes").font(.subheadline)
            }.disabled(read.isEmpty)
        }
    }
    private func block(_ title: String, _ b: [UInt8], from firstBlock: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = Hex.string(b)
                    copied = title
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label(copied == title ? "Copied" : "Copy", systemImage: copied == title ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            // 8 bytes per row = one NFC block; row label = block number
            Text(stride(from: 0, to: b.count, by: 8).map {
                String(format: "%03d  ", firstBlock + $0 / 8) + Hex.string(Array(b[$0..<min($0 + 8, b.count)]), separator: " ")
            }.joined(separator: "\n"))
            .font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
        }
    }
}

// MARK: - Building blocks

struct KV: View {
    let k: String; let v: String
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth: CGFloat = 100
    init(_ k: String, _ v: String) { self.k = k; self.v = v }
    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    if !k.isEmpty { Text(k).foregroundStyle(.secondary) }
                    Text(v).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .top) {
                    Text(k).foregroundStyle(.secondary).frame(width: labelWidth, alignment: .leading)
                    Text(v).font(.system(.subheadline, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

func dateTime(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

func tempText(_ t: Double?) -> String { t.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–" }

struct InfoCard: View { let text: String
    var body: some View {
        Label(text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct ErrorBanner: View { let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading).padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.red.opacity(0.12)))
            .foregroundStyle(.red)
    }
}

struct Card<Content: View>: View {
    let title: String; let icon: String; @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(Color(.secondarySystemGroupedBackground)))
    }
}

struct ScanButton: View {
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
