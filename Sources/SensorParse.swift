//  SensorParse.swift — parse a decrypted Libre 2 FRAM into calibration, state and
//  records, and compute mg/dL. Faithful to LoopKit/LibreTransmitter (MIT). No Abbott binary.
import Foundation

struct Record {
    let minuteOffset: Int       // minutes before scan (0 = newest)
    let rawGlucose: Int
    let rawTemperature: Int
    let rawTemperatureAdjustment: Int
    var glucose: Double?        // mg/dL via the calibration
}

struct ParsedSensor {
    let serial: String
    let generation: Int         // 1 or 2
    let minutesSinceStart: Int
    let maxMinutesWear: Int
    let headerCRC: Bool, bodyCRC: Bool, footerCRC: Bool
    let i1: Int, i2: Int, i3: Double, i4: Double, i5: Double, i6: Double
    let trend: [Record]         // 16 points, newest first
    var crcOK: Bool { headerCRC && bodyCRC && footerCRC }
    var ageHuman: String { "\(minutesSinceStart / 1440)d \((minutesSinceStart % 1440) / 60)h \(minutesSinceStart % 60)m" }
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
        guard fram.count >= 344 else { return nil }
        let body = Array(fram[24..<320]), footer = Array(fram[320..<344])

        // calibration (bit offsets from SensorData.calibrationData)
        let i1 = Libre2FRAM.readBits(fram, 2, 0, 3)
        let i2 = Libre2FRAM.readBits(fram, 2, 3, 0xa)
        let i3 = Double(Libre2FRAM.readBits(fram, 0x150, 0, 8))
        let i4 = Double(Libre2FRAM.readBits(fram, 0x150, 8, 0xe))
        let negI3 = Libre2FRAM.readBits(fram, 0x150, 0x21, 1) != 0
        let i5 = Double(Libre2FRAM.readBits(fram, 0x150, 0x28, 0xc) << 2)
        let i6 = Double(Libre2FRAM.readBits(fram, 0x150, 0x34, 0xc) << 2)

        let minutes = Int(body[293]) << 8 + Int(body[292])
        let nextTrend = Int(body[2])
        let maxWear = Int(footer[7]) << 8 + Int(footer[6])

        var trend = [Record]()
        for blockIndex in 0...15 {
            var index = 4 + (nextTrend - 1 - blockIndex) * 6
            if index < 4 { index += 96 }
            let b = Array(body[index..<index + 6])
            let rawGlucose = Libre2FRAM.readBits(b, 0, 0, 0xe)
            let rawTemp = Libre2FRAM.readBits(b, 0, 0x1a, 0xc) << 2
            let adj = Libre2FRAM.readBits(b, 0, 0x26, 0x9) << 2
            let rawAdj = (Libre2FRAM.readBits(b, 0, 0x2f, 1) != 0) ? -adj : adj
            var g: Double?
            if rawGlucose > 0, let t = temperature(rawTemp, rawAdj, i6) {
                g = glucose(rawGlucose: rawGlucose, i2: i2, i3: negI3 ? -i3 : i3, i4: i4, temp: t)
            }
            trend.append(Record(minuteOffset: blockIndex, rawGlucose: rawGlucose,
                                rawTemperature: rawTemp, rawTemperatureAdjustment: rawAdj, glucose: g))
        }

        return ParsedSensor(
            serial: serialNumber(uid: uid, patchInfo: patchInfo),
            generation: Libre2FRAM.securityGeneration(patchInfo),
            minutesSinceStart: minutes, maxMinutesWear: maxWear,
            headerCRC: Libre2FRAM.crcOK(fram[0..<24]),
            bodyCRC: Libre2FRAM.crcOK(fram[24..<320]),
            footerCRC: Libre2FRAM.crcOK(fram[320..<344]),
            i1: i1, i2: i2, i3: negI3 ? -i3 : i3, i4: i4, i5: i5, i6: i6, trend: trend)
    }

    // Libre serial from UID + sensor family. Exact port of LibreTransmitter SensorSerialNumber.
    static func serialNumber(uid: [UInt8], patchInfo: [UInt8]) -> String {
        guard uid.count == 8, patchInfo.count >= 3 else { return "-" }
        let lookup = Array("0123456789ACDEFGHJKLMNPQRTUVWXYZ")
        let family = Int(patchInfo[2] >> 4)
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
