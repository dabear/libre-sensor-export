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
    var generation: Int { patch.generation }

    /// Parsed and all CRCs match. Values from a FRAM that fails its CRCs are likely garbage
    /// (e.g. a batch that changed its encryption), so the reading, chart and dates are hidden.
    var trustworthy: Bool { parsed?.crcOK == true }
    /// Readings (tables, chart) exist for this scan.
    var hasReadings: Bool { parsed != nil }

    /// Whether the FRAM decrypted with the first-generation scheme (what LibreTransmitter#67 needs).
    var cryptoSummary: String {
        switch encryption {
        case .notRead:
            return patch.isLibre3 ? "not read (Libre 3)" : patch.generation == 2 ? "not read (Gen2)" : "not read"
        case .none: return "not encrypted (CRCs match as read)"
        case .libre2: return parsed?.crcOK == true ? "yes, all CRCs match" : "no, CRCs don't match"
        case .us14day: return parsed?.crcOK == true ? "US 14 day scheme, CRCs match" : "US 14 day scheme, CRCs don't match"
        case .undecryptable: return "can't decrypt without patch info"
        }
    }

    /// Why there are no readings, when there aren't.
    var notice: String? {
        if let p = parsed, !p.crcOK {
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
    if raw.count >= 344 {
        let plain = [0..<24, 24..<320, 320..<344].allSatisfy { Libre2FRAM.crcCheck(raw[$0]).ok }
        if plain {
            encryption = .none; fram = raw
        } else if let dec = Libre2FRAM.decryptFRAM(id: r.uid, info: r.patchInfo, data: raw) {
            encryption = Libre2FRAM.isLibre2(r.patchInfo) ? .libre2 : .us14day; fram = dec
        } else {
            encryption = .undecryptable
        }
    }
    let parsed = fram.isEmpty || patch.isLibrePro ? nil : SensorParse.parse(uid: r.uid, patchInfo: r.patchInfo, fram: fram)
    // Libre 3 serials aren't derived from the UID like Libre 1/2 ones; "–" means unknown
    let serial = patch.isLibre3 ? "–" : SensorParse.serialNumber(uid: r.uid, patchInfo: r.patchInfo)

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
    if let extra = r.tag.extraMemory { tag["extra_memory_hex"] = hex(extra); tag["extra_memory_from_block"] = 43 }
    tag["extra_memory_note"] = r.tag.extraMemoryNote

    var patchDecoded: [String: Any] = ["sensor_type": patch.sensorType, "sensor_type_pr67": patch.sensorTypePR67,
                                       "generation": patch.generation]
    patchDecoded["family"] = patch.family
    patchDecoded["security"] = patch.securityNibble
    patchDecoded["region_code"] = patch.regionCode
    patchDecoded["crypto_word"] = patch.cryptoWord

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
    if !raw.isEmpty { payload["decrypts_gen1"] = encryption == .libre2 && parsed?.crcOK == true }
    if let p = parsed {
        payload["sensor_state"] = p.state
        payload["max_minutes_wear"] = p.maxMinutesWear
        payload["next_trend_block"] = p.nextTrendBlock
        payload["next_history_block"] = p.nextHistoryBlock
        payload["fram_region"] = p.regionByte
        payload["started_at"] = iso.string(from: r.scannedAt.addingTimeInterval(-60 * Double(p.minutesSinceStart)))
        payload["ends_at"] = iso.string(from: r.scannedAt.addingTimeInterval(60 * Double(p.maxMinutesWear - p.minutesSinceStart)))
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
    if let b0 = p.raw.first, let f = p.family, let sec = p.securityNibble {
        lines.append("Byte 0 \(Hex.byte(Int(b0))) · family \(f) (\(p.familyName)) · security version \(sec) → \(p.generationShort) · region \(p.regionName)\(p.regionCode.map { " (\(Hex.byte($0)))" } ?? "")")
    }
    if let err = e.result.patchInfoError { lines.append("Patch info not answered: \(err)") }
    lines.append("LibreTransmitter type: \(p.sensorType) (main) · \(p.sensorTypePR67) (PR #67)")
    lines.append("FRAM encryption: \(e.encryption.label) · Gen1 crypto: \(e.cryptoSummary)")
    if let s = e.parsed {
        lines.append("State: \(SensorLabels.state(s.state)) · age \(s.ageHuman) · wear time \(ParsedSensor.human(s.maxMinutesWear))")
        let flagged = (s.trend + s.history).filter { $0.errorBits != 0 }.count
        if flagged > 0 { lines.append("Readings with quality flags: \(flagged) of \(s.trend.count + s.history.count)") }
    }
    let t = e.result.tag
    var chip = "NFC chip: \(SensorLabels.icManufacturer(t.icManufacturerCode)) (\(Hex.byte(t.icManufacturerCode)))"
    if let si = t.systemInfo { chip += " · \(si.totalBlocks) blocks × \(si.blockSize) bytes · IC ref \(si.icReference < 0 ? "–" : Hex.byte(si.icReference))" }
    lines.append(chip)
    lines.append("Scanned: \(ISO8601DateFormatter().string(from: e.result.scannedAt))")
    let info = Bundle.main.infoDictionary
    let os = ProcessInfo.processInfo.operatingSystemVersion
    lines.append("App: Libre Export \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?")) · iOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(deviceModel())")
    return lines.joined(separator: "\n")
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
    do { try e.prettyJSON.write(to: url, options: .atomic); return url } catch { return nil }
}
