//  SensorParse.swift — parse a decrypted Libre 2 FRAM into calibration, state and
//  records, and compute mg/dL. Faithful to LoopKit/LibreTransmitter (MIT). No Abbott binary.
import Foundation

struct Record {
    let minuteOffset: Int       // minutes before scan (0 = newest)
    let rawGlucose: Int
    let rawTemperature: Int
    let rawTemperatureAdjustment: Int
    var temperature: Double?    // °C via the thermistor formula
    var glucose: Double?        // mg/dL via the calibration
    var errorBits: Int = 0      // SensorLabels.measurementErrors; 0 = no flags
}

/// One FRAM region's CRC: the two stored bytes and the CRC of the rest.
struct CRCCheck {
    let stored: UInt16, computed: UInt16
    var ok: Bool { stored == computed }
}

struct ParsedSensor {
    let serial: String
    let state: Int              // header byte 4 (SensorLabels.state)
    let minutesSinceStart: Int
    let maxMinutesWear: Int
    let nextTrendBlock: Int     // body byte 2
    let nextHistoryBlock: Int   // body byte 3
    let regionByte: Int         // FRAM byte 323
    let headerCRC: CRCCheck, bodyCRC: CRCCheck, footerCRC: CRCCheck
    let i1: Int, i2: Int, i3: Double, i4: Double, i5: Double, i6: Double
    let trend: [Record]         // 16 points, 1 min apart, newest first
    let history: [Record]       // 32 points, 15 min apart, newest first
    var crcOK: Bool { headerCRC.ok && bodyCRC.ok && footerCRC.ok }
    var minutesLeft: Int { max(maxMinutesWear - minutesSinceStart, 0) }
    /// Minutes of the 1 h warm-up still to go (LibreTransmitter's warmupPeriod), nil when done.
    var warmupMinutesLeft: Int? {
        (state == 2 && minutesSinceStart < 60) ? 60 - minutesSinceStart : nil   // not for state 1 (not started)
    }
    /// Minutes since the wear time ran out, nil while it hasn't.
    var expiredMinutesAgo: Int? {
        maxMinutesWear > 0 && minutesSinceStart > maxMinutesWear ? minutesSinceStart - maxMinutesWear : nil
    }
    /// mg/dL per minute: least-squares slope over the last 15 trend minutes (needs 5 values).
    var trendRate: Double? {
        let pts = trend.filter { $0.minuteOffset < 15 }.compactMap { r in r.glucose.map { (Double(-r.minuteOffset), $0) } }
        guard pts.count >= 5 else { return nil }
        let n = Double(pts.count)
        let mx = pts.map(\.0).reduce(0, +) / n, my = pts.map(\.1).reduce(0, +) / n
        let sxx = pts.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        guard sxx > 0 else { return nil }
        return pts.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +) / sxx
    }
    var ageHuman: String { Self.human(minutesSinceStart) }
    var leftHuman: String { Self.human(minutesLeft) }
    static func human(_ m: Int) -> String { "\(m / 1440)d \((m % 1440) / 60)h \(m % 60)m" }
}

enum SensorParse {

    // Steinhart-Hart thermistor + linear glucose calibration (public math).
    private static let ca = 0.0009180023, cb = 0.0001964561, cc = 0.0000007061775, cd = 0.00000005283566

    static func temperature(_ rawTemp: Int, _ rawAdj: Int, _ i6: Double) -> Double? {
        let rRight = Double(rawAdj) + i6
        guard rRight > 0 else { return nil }
        let R = Double(rawTemp) * (1000 + 71500) / rRight - 1000
        guard R > 0 else { return nil }
        let logR = Foundation.log(R)
        let d = ((cd * logR + cc) * logR + cb) * logR + ca
        let t = 1 / d - 273.15
        return (10...45).contains(t) ? t : nil
    }

    static func glucose(rawGlucose: Int, i2: Int, i3: Double, i4: Double, temp: Double) -> Double? {
        let idx = i2 - 1
        guard (0..<Tables.t1.count).contains(idx), i4 != i3 else { return nil }
        let g1 = 65 * (Double(rawGlucose) - i3) / (i4 - i3)
        let g2 = Foundation.pow(1.045, 32.5 - temp)
        let g = (g1 * g2 - Tables.t1[idx]) / Tables.t2[idx]
        return g.isFinite ? g : nil
    }

    /// Parse a decrypted 344-byte FRAM. `uid` and `patchInfo` are as read over NFC.
    static func parse(uid: [UInt8], patchInfo: [UInt8], fram: [UInt8]) -> ParsedSensor? {
        guard fram.count >= FRAMLayout.size else { return nil }
        let body = Array(fram[FRAMLayout.body]), footer = Array(fram[FRAMLayout.footer])

        // calibration (bit offsets from SensorData.calibrationData)
        let i1 = Libre2FRAM.readBits(fram, 2, 0, 3)
        let i2 = Libre2FRAM.readBits(fram, 2, 3, 0xa)
        let i3 = Double(Libre2FRAM.readBits(fram, 0x150, 0, 8))
        let i4 = Double(Libre2FRAM.readBits(fram, 0x150, 8, 0xe))
        let negI3 = Libre2FRAM.readBits(fram, 0x150, 0x21, 1) != 0
        let i5 = Double(Libre2FRAM.readBits(fram, 0x150, 0x28, 0xc) << 2)
        let i6 = Double(Libre2FRAM.readBits(fram, 0x150, 0x34, 0xc) << 2)

        let minutes = Int(body[293]) << 8 + Int(body[292])
        // modulo: a corrupt FRAM must not index outside the ring buffers
        let nextTrend = Int(body[2]) % 16
        let nextHistory = Int(body[3]) % 32
        let maxWear = Int(footer[7]) << 8 + Int(footer[6])
        let cal3 = negI3 ? -i3 : i3

        func record(_ b: [UInt8], minuteOffset: Int) -> Record {
            let rawGlucose = Libre2FRAM.readBits(b, 0, 0, 0xe)
            let rawTemp = Libre2FRAM.readBits(b, 0, 0x1a, 0xc) << 2
            let adj = Libre2FRAM.readBits(b, 0, 0x26, 0x9) << 2
            let rawAdj = (Libre2FRAM.readBits(b, 0, 0x2f, 1) != 0) ? -adj : adj
            let t = temperature(rawTemp, rawAdj, i6)
            var g: Double?
            // as LibreTransmitter: values outside (0, 500] mg/dL aren't readings (the raw values stay)
            if rawGlucose > 0, let t, let v = glucose(rawGlucose: rawGlucose, i2: i2, i3: cal3, i4: i4, temp: t),
               v > 0, v <= 500 { g = v }
            return Record(minuteOffset: minuteOffset, rawGlucose: rawGlucose, rawTemperature: rawTemp,
                          rawTemperatureAdjustment: rawAdj, temperature: t, glucose: g,
                          errorBits: Libre2FRAM.readBits(b, 0, 0xe, 0xc))
        }

        // Trend: body 4..<100, 16 x 6 bytes, one per minute.
        var trend = [Record]()
        for blockIndex in 0...15 {
            var index = 4 + (nextTrend - 1 - blockIndex) * 6
            if index < 4 { index += 96 }
            trend.append(record(Array(body[index..<index + 6]), minuteOffset: blockIndex))
        }

        // History: body 100..<292, 32 x 6 bytes, one per 15 min. Age of the newest as
        // LibreTransmitter's dateOfMostRecentHistoryValue (written 3 min after each quarter).
        let delay = (minutes - 3) % 15 + 3
        let inSync = ((minutes - 3) / 15) % 32 == nextHistory
        let newestAgo = inSync ? delay : delay - 15
        var history = [Record]()
        for blockIndex in 0..<32 {
            var index = 100 + (nextHistory - 1 - blockIndex) * 6
            if index < 100 { index += 192 }
            history.append(record(Array(body[index..<index + 6]), minuteOffset: newestAgo + 15 * blockIndex))
        }

        return ParsedSensor(
            serial: serialNumber(uid: uid, patchInfo: patchInfo),
            state: Int(fram[4]),
            minutesSinceStart: minutes, maxMinutesWear: maxWear,
            nextTrendBlock: nextTrend, nextHistoryBlock: nextHistory,
            regionByte: Int(fram[323]),
            headerCRC: Libre2FRAM.crcCheck(fram[FRAMLayout.header]),
            bodyCRC: Libre2FRAM.crcCheck(fram[FRAMLayout.body]),
            footerCRC: Libre2FRAM.crcCheck(fram[FRAMLayout.footer]),
            i1: i1, i2: i2, i3: cal3, i4: i4, i5: i5, i6: i6, trend: trend, history: history)
    }

    // Libre serial from UID + sensor family. Exact port of LibreTransmitter SensorSerialNumber.
    static func serialNumber(uid: [UInt8], patchInfo: [UInt8]) -> String {
        guard uid.count == 8 else { return "–" }
        let lookup = Array("0123456789ACDEFGHJKLMNPQRTUVWXYZ")
        // Libre 1 sensors that don't answer the patch info command: family 0
        let family = patchInfo.count >= 3 ? Int(patchInfo[2] >> 4) : 0
        let b = Array(uid.reversed().suffix(6))   // 6 bytes
        let five: [UInt8] = [
            b[0] >> 3,
            (b[0] &<< 2) &+ (b[1] >> 6),
            b[1] >> 1,
            (b[1] &<< 4) &+ (b[2] >> 4),
            (b[2] &<< 1) &+ (b[3] >> 7),
            b[3] >> 2,
            (b[3] &<< 3) &+ (b[4] >> 5),
            b[4],
            b[5] >> 3,
            b[5] &<< 2,
        ]
        return five.reduce("\(family)") { $0 + String(lookup[Int($1 & 0x1F)]) }
    }
}
