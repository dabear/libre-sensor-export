//  Export.swift — turn a scan into what the app shows and shares: decrypted + parsed FRAM,
//  the JSON export (file and base64), and a short report without identifiers.
import Foundation

enum FramEncryption: String {
    case notRead = "not_read"
    case none                    // CRCs match as read: Libre 1 style, not encrypted
    case libre2                  // first-generation Libre 2 scheme
    case us14day                 // Libre US 14 day scheme
    case undecryptable           // encrypted, but no patch info to decrypt with

    /// The same words on screen and in the report.
    var label: String {
        switch self {
        case .notRead: return "not read"
        case .none: return "none (Libre 1 style)"
        case .libre2: return "Libre 2, first generation"
        case .us14day: return "Libre US 14 day"
        case .undecryptable: return "encrypted, no patch info to decrypt with"
        }
    }
}

struct Export {
    let result: ScanResult
    let parsed: ParsedSensor?
    let patch: PatchInfoDecoded
    let serial: String
    let encryption: FramEncryption
    let framDecrypted: [UInt8]   // the FRAM as parsed (equal to the read bytes when not encrypted)
    let payload: [String: Any]   // the export; serialised only when shared

    var json: Data { (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data() }
    var prettyJSON: Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
    var base64: String { json.base64EncodedString() }

    /// Parsed and all CRCs match. Values from a FRAM that fails its CRCs are likely garbage
    /// (e.g. a batch that changed its encryption), so the reading, chart and dates are hidden.
    var trustworthy: Bool { parsed?.crcOK == true }
    /// Readings (tables, chart) exist for this scan.
    var hasReadings: Bool { parsed != nil }
    /// Header and footer CRCs match: the scheme is right. The body changes every minute, so a body
    /// mismatch alone usually means the read overlapped an update.
    var decrypts: Bool { parsed.map { $0.headerCRC.ok && $0.footerCRC.ok } ?? false }

    /// The summary line, naming an unencrypted sensor without patch info as the Libre 1 it is.
    var summary: String { patch.raw.isEmpty && encryption == .none ? "Libre 1 · no patch info" : patch.summary }

    /// What this scan means for LibreTransmitter, in one line.
    var ltVerdict: String {
        if patch.isLibre3 { return "Libre 3: not read over NFC by LibreTransmitter" }
        if patch.generation == 2 { return "Gen2: needs the authenticated read" }
        if encryption == .notRead || encryption == .undecryptable { return "can't tell without the memory" }
        let today = patch.sensorType != "Unknown", withPR = patch.sensorTypePR67 != "Unknown"
        let reads = encryption == .none || decrypts
        switch (today, withPR, reads) {
        case (true, _, true): return "works today"
        case (false, true, true): return "works with PR #67"
        case (_, true, false): return "type accepted, but it doesn't decrypt: PR #67 alone won't make it work"
        default: return "not supported"
        }
    }

    /// Whether the FRAM decrypted with the first-generation scheme (what LibreTransmitter#67 needs).
    var cryptoSummary: String {
        switch encryption {
        case .notRead:
            return patch.isLibre3 ? "not read (Libre 3)" : patch.generation == 2 ? "not read (Gen2)" : "not read"
        case .none: return "not encrypted (CRCs match as read)"
        case .libre2:
            return !decrypts ? "no, CRCs don't match" : parsed?.bodyCRC.ok == true ? "yes, all CRCs match" : "yes; body CRC mismatch, scan again"
        case .us14day:
            return !decrypts ? "US 14 day scheme, CRCs don't match"
                : parsed?.bodyCRC.ok == true ? "US 14 day scheme, CRCs match" : "US 14 day scheme; body CRC mismatch, scan again"
        case .undecryptable: return "can't decrypt without patch info"
        }
    }

    /// Why there are no readings, when there aren't.
    var notice: String? {
        if let p = parsed, !p.crcOK {
            if p.headerCRC.ok && p.footerCRC.ok {
                return "Only the body CRC doesn't match: the sensor probably updated its memory during the read. Scan again. Until then the glucose, chart and dates are hidden."
            }
            return "The CRCs don't match after \(encryption == .none ? "reading" : "decrypting"), so the glucose, dates and readings are likely garbage and are hidden here. Readings and Technical still show what was decoded."
        }
        guard parsed == nil else { return nil }
        if patch.isLibre3 { return "Libre 3: its memory can't be read over NFC, so only the patch info and chip details are shown." }
        if patch.generation == 2 { return "Gen2 sensor: its memory needs the authenticated read, so only the patch info and chip details are shown." }
        if patch.isLibrePro { return "Libre Pro/H keeps a different memory layout, which this app doesn't parse. The raw bytes are in the export." }
        if encryption == .undecryptable { return "The memory is encrypted, but the sensor didn't give its patch info, so it can't be decrypted. The raw bytes are in the export." }
        return "The memory didn't parse. The raw bytes are in the export for offline analysis."
    }
}

func makeExport(_ r: ScanResult) -> Export {
    func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    let iso = ISO8601DateFormatter()
    let patch = PatchInfoDecoded(raw: r.patchInfo)

    // Plain FRAM (Libre 1) already passes its CRCs; otherwise decrypt with the patch info.
    var encryption = FramEncryption.notRead
    var fram: [UInt8] = []
    let raw = r.framEncrypted
    if raw.count >= FRAMLayout.size {
        // header and footer only: the body changes every minute and can fail when a read overlaps an update
        let plain = Libre2FRAM.crcCheck(raw[FRAMLayout.header]).ok && Libre2FRAM.crcCheck(raw[FRAMLayout.footer]).ok
        // never decrypt a Libre 1 or Pro: their memory isn't encrypted (a CRC failure is just that)
        if plain || patch.sensorType == "Libre 1" || patch.isLibrePro {
            encryption = .none; fram = raw
        } else if let dec = Libre2FRAM.decryptFRAM(id: r.uid, info: r.patchInfo, data: raw) {
            encryption = Libre2FRAM.isLibre2(r.patchInfo) ? .libre2 : .us14day; fram = dec
        } else {
            encryption = .undecryptable
        }
    }
    let parsed = fram.isEmpty || patch.isLibrePro ? nil : SensorParse.parse(uid: r.uid, patchInfo: r.patchInfo, fram: fram)
    // Libre 3 serials aren't derived from the UID like Libre 1/2 ones; "–" means unknown
    // (an encrypted sensor that gave no patch info has an unknown family digit)
    let serial = patch.isLibre3 || (patch.raw.isEmpty && encryption != .none && encryption != .notRead) ? "–"
        : SensorParse.serialNumber(uid: r.uid, patchInfo: r.patchInfo)

    func records(_ rs: [Record]) -> [[String: Any]] {
        rs.map {
            var d: [String: Any] = ["minute": -$0.minuteOffset, "raw_glucose": $0.rawGlucose,
                                    "raw_temperature": $0.rawTemperature,
                                    "raw_temperature_adjustment": $0.rawTemperatureAdjustment,
                                    "error_flags": $0.errorBits]
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
    tag["system_info_error"] = r.tag.systemInfoError
    tag["block_security"] = r.tag.blockSecurity
    tag["block_security_error"] = r.tag.blockSecurityError
    if let extra = r.tag.extraMemory { tag["extra_memory_hex"] = hex(extra); tag["extra_memory_from_block"] = FRAMLayout.blocks }
    tag["extra_memory_note"] = r.tag.extraMemoryNote

    var patchDecoded: [String: Any] = ["sensor_type": patch.sensorType, "sensor_type_pr67": patch.sensorTypePR67,
                                       "generation": patch.generation]
    patchDecoded["family"] = patch.family
    patchDecoded["security"] = patch.securityNibble
    patchDecoded["region_code"] = patch.regionCode
    patchDecoded["crypto_word"] = patch.cryptoWord
    if patch.isLibre3 {   // the Libre 2 decoding of these bytes means nothing for a Libre 3
        for key in ["generation", "family", "security", "region_code", "crypto_word"] { patchDecoded[key] = nil }
    }

    var payload: [String: Any] = [
        "format": "libre2-fram-export-v1",
        "scanned_at": iso.string(from: r.scannedAt),
        "uid": hex(r.uid), "patch_info": hex(r.patchInfo),
        "patch_info_decoded": patchDecoded,
        "serial": serial,
        "tag": tag,
        "generation": patch.generation,
        "fram_encryption": encryption.rawValue,
        "fram_encrypted_hex": hex(r.framEncrypted), "fram_decrypted_hex": hex(fram),   // = as read when not encrypted
        "minutes_since_start": parsed?.minutesSinceStart ?? -1,
        "calibration": parsed.map { ["i1": $0.i1, "i2": $0.i2, "i3": $0.i3, "i4": $0.i4, "i5": $0.i5, "i6": $0.i6] } ?? [:],
        "trend_records": records(parsed?.trend ?? []),
        "history_records": records(parsed?.history ?? []),
    ]
    payload["patch_info_error"] = r.patchInfoError
    payload["app_version"] = appVersion()
    if patch.isLibre3 { payload["generation"] = nil }
    if !raw.isEmpty { payload["decrypts_gen1"] = encryption == .libre2 && (parsed.map { $0.headerCRC.ok && $0.footerCRC.ok } ?? false) }
    if let p = parsed {
        payload["sensor_state"] = p.state
        payload["crc_ok"] = p.crcOK
        payload["max_minutes_wear"] = p.maxMinutesWear
        payload["next_trend_block"] = p.nextTrendBlock
        payload["next_history_block"] = p.nextHistoryBlock
        payload["fram_region"] = p.regionByte
        if p.state >= 2 {   // a sensor that hasn't started has no start or end yet
            payload["started_at"] = iso.string(from: r.scannedAt.addingTimeInterval(-60 * Double(p.minutesSinceStart)))
            payload["ends_at"] = iso.string(from: r.scannedAt.addingTimeInterval(60 * Double(p.maxMinutesWear - p.minutesSinceStart)))
        }
        payload["trend_rate_mgdl_per_min"] = p.trendRate.map { ($0 * 100).rounded() / 100 }
        payload["crc"] = ["header": ["stored": p.headerCRC.stored, "computed": p.headerCRC.computed],
                          "body": ["stored": p.bodyCRC.stored, "computed": p.bodyCRC.computed],
                          "footer": ["stored": p.footerCRC.stored, "computed": p.footerCRC.computed]]
    }
    return Export(result: r, parsed: parsed, patch: patch, serial: serial, encryption: encryption,
                  framDecrypted: fram, payload: payload)
}

/// A short text for bug reports and PRs: what identifies the batch and the result, but no UID,
/// serial, readings, or the sensor-specific patch info bytes 4–5.
func makeReport(_ e: Export) -> String {
    let p = e.patch
    var patchText = "–"
    if !p.raw.isEmpty {
        patchText = p.raw.enumerated().map { $0.offset < 4 ? String(format: "%02X", $0.element) : ".." }
            .joined(separator: " ")
    }
    var lines = ["Libre Export report",
                 "Patch info: \(patchText)" + (p.raw.count > 4 ? " (bytes 4 and up left out)" : "")]
    if !p.isLibre3, let b0 = p.raw.first, let f = p.family, let sec = p.securityNibble {
        lines.append("Byte 0 \(Hex.byte(Int(b0))) · family \(f) (\(p.familyName)) · security version \(sec) → \(p.generationShort) · region \(p.regionName)\(p.regionCode.map { " (\(Hex.byte($0)))" } ?? "")")
    }
    if let err = e.result.patchInfoError { lines.append("Patch info not answered: \(err)") }
    lines.append("LibreTransmitter type: \(p.sensorType) (main) · \(p.sensorTypePR67) (PR #67) · verdict: \(e.ltVerdict)")
    lines.append("\(e.encryption == .libre2 || e.encryption == .us14day ? "Decryption tried" : "FRAM encryption"): \(e.encryption.label) · Gen1 crypto: \(e.cryptoSummary)")
    if let s = e.parsed, e.trustworthy {
        // age to the hour: with the scan date it doesn't pin down the exact start minute
        lines.append("State: \(SensorLabels.state(s.state)) · age \(s.minutesSinceStart / 1440)d \((s.minutesSinceStart % 1440) / 60)h · wear time \(ParsedSensor.human(s.maxMinutesWear))")
        let flagged = (s.trend + s.history).filter { $0.errorBits != 0 }.count
        if flagged > 0 { lines.append("Readings with quality flags: \(flagged) of \(s.trend.count + s.history.count)") }
    }
    let t = e.result.tag
    var chip = "NFC chip: \(SensorLabels.icManufacturer(t.icManufacturerCode)) (\(Hex.byte(t.icManufacturerCode)))"
    if let si = t.systemInfo { chip += " · \(si.totalBlocks) blocks × \(si.blockSize) bytes · IC ref \(si.icReference < 0 ? "–" : Hex.byte(si.icReference))" }
    lines.append(chip)
    lines.append("Scanned: \(e.result.scannedAt.formatted(.iso8601.year().month().day()))")
    let os = ProcessInfo.processInfo.operatingSystemVersion
    lines.append("App: Libre Export \(appVersion()) · iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(deviceModel())")
    return lines.joined(separator: "\n")
}

/// "1.2 (3)", from the bundle.
func appVersion() -> String {
    let info = Bundle.main.infoDictionary
    return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
}

/// Hardware model identifier, e.g. "iPhone17,1" (no name or other identifier of the user).
func deviceModel() -> String {
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// Writes the pretty JSON to a temporary file named after the scan time, for the share sheet.
func exportFile(_ e: Export) -> URL? {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    f.locale = Locale(identifier: "en_US_POSIX")
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("libre-export-\(f.string(from: e.result.scannedAt)).json")
    do { try e.prettyJSON.write(to: url, options: [.atomic, .completeFileProtection]); return url } catch { return nil }
}

/// Deletes JSON files left from earlier shares (they hold everything, including identifiers).
func removeExportFiles() {
    let tmp = FileManager.default.temporaryDirectory
    for f in (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
    where f.lastPathComponent.hasPrefix("libre-export-") { try? FileManager.default.removeItem(at: f) }
}
