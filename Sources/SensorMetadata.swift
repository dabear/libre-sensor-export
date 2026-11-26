//  SensorMetadata.swift — everything a scan tells us besides glucose: the NFC tag's own
//  info, the decoded patch info, and labels for FRAM header/footer fields. Sensor type and
//  state labels follow LoopKit/LibreTransmitter (MIT); anything not decoded there is shown raw.
import Foundation

/// ISO 15693 Get System Info answer. -1 means the tag left that field out.
struct TagSystemInfo: Codable {
    let dsfid: Int
    let afi: Int
    let blockSize: Int
    let totalBlocks: Int
    let icReference: Int
}

/// What CoreNFC tells us about the tag itself.
struct TagInfo: Codable {
    let icManufacturerCode: Int
    let icSerialNumber: [UInt8]
    var systemInfo: TagSystemInfo?
    var systemInfoError: String?
    /// ISO 15693 block security status from block 0 (bit 0 set = block locked).
    var blockSecurity: [Int]?
    var blockSecurityError: String?
    /// Blocks after the 43 FRAM blocks, from block 43 on (only with "Read all memory").
    var extraMemory: [UInt8]?
    /// How far that read got, and why it stopped.
    var extraMemoryNote: String?
}

/// Runs of equal values, e.g. block security statuses: [(first block, last block, value)].
func runs(_ values: [Int]) -> [(first: Int, last: Int, value: Int)] {
    var out: [(first: Int, last: Int, value: Int)] = []
    for (i, v) in values.enumerated() {
        if let last = out.last, last.value == v, last.last == i - 1 { out[out.count - 1].last = i }
        else { out.append((i, i, v)) }
    }
    return out
}

enum Hex {
    static func string(_ b: [UInt8], separator: String = "") -> String {
        b.map { String(format: "%02X", $0) }.joined(separator: separator)
    }
    static func byte(_ v: Int) -> String { String(format: "0x%02X", v) }
    static func word(_ v: Int) -> String { String(format: "0x%04X", v) }
}

/// Patch info (custom command 0xA1), decoded as far as is known.
struct PatchInfoDecoded {
    let raw: [UInt8]

    /// LibreTransmitter `SensorType(patchInfo:)` on `main`, before LoopKit/LibreTransmitter#67.
    var sensorType: String {
        guard let b0 = raw.first else { return "Unknown" }
        switch b0 {
        case 0xDF, 0xA2: return "Libre 1"
        case 0xE5, 0xE6: return "Libre US 14 day"
        case 0x70: return "Libre Pro/H"
        case 0xC5, 0x9D, 0xC6, 0x7F: return "Libre 2"
        case 0x76:
            guard raw.count >= 4 else { return "Unknown" }
            if raw[3] == 0x02 { return "Libre 2 US" }
            if raw[3] == 0x04 { return "Libre 2 CA" }
            if raw[2] >> 4 == 7 { return "Libre Sense" }
            return "Unknown"
        default:
            return raw.count == 24 ? "Libre 3" : "Unknown"
        }
    }

    /// The same with LoopKit/LibreTransmitter#67: byte 0 `0x84` is Libre 2, and an unlisted
    /// byte 0 is Libre 2 when the rest says first-generation Libre 2 EU.
    var sensorTypePR67: String {
        guard let b0 = raw.first else { return "Unknown" }
        if b0 == 0x84 { return "Libre 2" }
        let listed = [0xDF, 0xA2, 0xE5, 0xE6, 0x70, 0xC5, 0x9D, 0xC6, 0x7F, 0x76].contains(Int(b0))
        if !listed, raw.count != 24, isFirstGenerationLibre2EU { return "Libre 2" }
        return sensorType
    }

    /// PR #67's fallback rule: 6 bytes, family 3, security version below 9, region 0x01.
    var isFirstGenerationLibre2EU: Bool {
        raw.count == 6 && raw[2] >> 4 == 3 && raw[2] & 0x0F < 9 && raw[3] == 0x01
    }

    /// High nibble of byte 2 (product family; also the serial number's first digit).
    var family: Int? { raw.count >= 3 ? Int(raw[2] >> 4) : nil }
    var familyName: String {
        switch family {
        case 3: return "Libre 2"
        case nil: return "–"
        default: return "other"
        }
    }
    /// Low nibble of byte 2: the security version (9 or more on a family-3 patch = Gen2).
    var securityNibble: Int? { raw.count >= 3 ? Int(raw[2] & 0x0F) : nil }
    var generation: Int { Libre2FRAM.securityGeneration(raw) }
    /// Libre 3 answers the patch info command with 24 bytes (as LibreTransmitter checks).
    var isLibre3: Bool { raw.count == 24 }
    /// Libre Pro/H keeps a different memory layout, which this app doesn't parse.
    var isLibrePro: Bool { raw.first == 0x70 }
    var regionCode: Int? { raw.count >= 4 ? Int(raw[3]) : nil }
    /// Bytes 5..4, the word the Libre 2 FRAM decryption uses.
    var cryptoWord: Int? { raw.count >= 6 ? Int(raw[5]) << 8 | Int(raw[4]) : nil }

    var regionName: String { regionCode.map(SensorLabels.region) ?? "–" }

    /// One line for the top of the screen, the same for every scan: type, then region and
    /// generation where the Libre 2 decoding applies.
    var summary: String {
        if raw.isEmpty { return "No patch info" }
        if isLibre3 { return "Libre 3" }
        var parts = [sensorTypePR67]
        if regionCode != nil { parts.append(regionName) }
        if generation > 0 { parts.append(generationShort) }
        return parts.joined(separator: " · ")
    }

    var generationShort: String {
        switch generation {
        case 2: return "Gen2"
        case 1: return "Gen1"
        default: return "other gen"
        }
    }

    var generationLabel: String {
        switch generation {
        case 2: return "Gen2 (authenticated NFC)"
        case 1: return "Gen1 (Libre 2 / US 14 day)"
        default: return "Other"
        }
    }
}

enum SensorLabels {
    /// Region codes as used by the open-source Libre apps (patch info byte 3, FRAM byte 323).
    static func region(_ code: Int) -> String {
        switch code {
        case 1: return "Europe"
        case 2: return "US"
        case 4: return "Australia / Canada"
        case 8: return "Rest of world"
        default: return "Unknown"
        }
    }

    /// FRAM header byte 4, as LibreTransmitter's `SensorState`.
    static func state(_ b: Int) -> String {
        switch b {
        case 1: return "Not yet started"
        case 2: return "Starting (warm-up)"
        case 3: return "Ready"
        case 4: return "Expired"
        case 5: return "Shut down"
        case 6: return "Failure"
        default: return "Unknown"
        }
    }

    /// Error bits of a glucose record (12 bits from bit 14), as LibreTransmitter's MeasurementError.
    static func measurementErrors(_ bits: Int) -> [String] {
        let names: [(Int, String)] = [
            (0x001, "FIFO overflow"), (0x002, "filter delta"), (0x004, "work voltage"),
            (0x008, "peak delta exceeded"), (0x010, "average delta exceeded"), (0x020, "RF"),
            (0x040, "reference R"), (0x080, "signal saturated"), (0x100, "signal low"),
            (0x800, "thermistor out of range"),
        ]
        var out = names.filter { bits & $0.0 != 0 }.map(\.1)
        let unknown = bits & ~names.reduce(0) { $0 | $1.0 }
        if unknown != 0 { out.append("unknown \(Hex.word(unknown))") }
        return out
    }

    /// ISO/IEC 7816-6 IC manufacturer codes likely on a CGM patch.
    static func icManufacturer(_ code: Int) -> String {
        switch code {
        case 0x02: return "STMicroelectronics"
        case 0x04: return "NXP"
        case 0x07: return "Texas Instruments"
        case 0x16: return "EM Microelectronic"
        default: return "Unknown"
        }
    }
}
