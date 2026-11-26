//  LibreExportTests.swift — decryption, parsing, export and report, on the synthetic demo sensor
//  (DemoScan: made-up UID and patch info `84 0E 30 01 4B 2E`, a "303" Libre 2 EU).
import XCTest
@testable import LibreSensorExport

final class LibreExportTests: XCTestCase {
    private let demo = DemoScan.result()

    private func scan(patchInfo: [UInt8]? = nil, fram: [UInt8]? = nil) -> ScanResult {
        ScanResult(uid: demo.uid, patchInfo: patchInfo ?? demo.patchInfo, framEncrypted: fram ?? demo.framEncrypted,
                   tag: demo.tag, scannedAt: demo.scannedAt)
    }

    func testDemoDecryptsAndParses() throws {
        let e = makeExport(demo)
        XCTAssertEqual(e.encryption, .libre2)
        XCTAssertTrue(e.trustworthy)
        let p = try XCTUnwrap(e.parsed)
        XCTAssertEqual(p.minutesSinceStart, 6127)
        XCTAssertEqual(p.maxMinutesWear, 20160)
        XCTAssertEqual(p.state, 3)
        XCTAssertEqual([p.i2, Int(p.i3), Int(p.i4), Int(p.i6)], [200, 20, 1550, 4000])
        XCTAssertEqual(try XCTUnwrap(p.trend.first?.glucose), 117, accuracy: 1)
        XCTAssertEqual(p.trend.count, 16)
        XCTAssertEqual(p.history.count, 32)
        XCTAssertEqual(e.cryptoSummary, "yes, all CRCs match")
        XCTAssertEqual(e.ltVerdict, "works with PR #67")
    }

    func testBodyOnlyCRCFailureIsNotWrongEncryption() {
        var fram = demo.framEncrypted
        fram[100] ^= 0x5A   // a body byte: as when a read overlaps the sensor's minute update
        let e = makeExport(scan(fram: fram))
        XCTAssertEqual(e.encryption, .libre2)
        XCTAssertTrue(e.decrypts)
        XCTAssertFalse(e.trustworthy)
        XCTAssertEqual(e.cryptoSummary, "yes; body CRC mismatch, scan again")
        XCTAssertEqual(e.payload["decrypts_gen1"] as? Bool, true)
        XCTAssertEqual(e.payload["crc_ok"] as? Bool, false)
    }

    func testPlainLibre1WithoutPatchInfo() {
        let plain = Libre2FRAM.decryptFRAM(id: demo.uid, info: demo.patchInfo, data: demo.framEncrypted)!
        let e = makeExport(scan(patchInfo: [], fram: plain))
        XCTAssertEqual(e.encryption, FramEncryption.none)
        XCTAssertTrue(e.trustworthy)
        XCTAssertEqual(e.summary, "Libre 1 · no patch info")
    }

    func testEncryptedWithoutPatchInfoHasNoSerial() {
        let e = makeExport(scan(patchInfo: []))
        XCTAssertEqual(e.encryption, .undecryptable)
        XCTAssertEqual(e.serial, "–")
    }

    func testReportHasNoIdentifiers() {
        let e = makeExport(demo)
        let report = makeReport(e)
        for secret in [e.serial, Hex.string(demo.uid), Hex.string(demo.uid.reversed()),
                       "4B 2E", "4B2E", Hex.string(demo.tag.icSerialNumber)] {
            XCTAssertFalse(report.uppercased().contains(secret.uppercased()), "report contains \(secret)")
        }
        XCTAssertTrue(report.contains("84 0E 30 01"))
    }

    func testExportKeys() {
        let e = makeExport(demo)
        for key in ["format", "scanned_at", "uid", "patch_info", "patch_info_decoded", "serial", "tag", "generation",
                    "fram_encryption", "fram_encrypted_hex", "fram_decrypted_hex", "minutes_since_start", "calibration",
                    "trend_records", "history_records", "decrypts_gen1", "crc_ok", "sensor_state", "started_at",
                    "ends_at", "crc", "app_version"] {
            XCTAssertNotNil(e.payload[key], key)
        }
        XCTAssertEqual(e.payload["format"] as? String, "libre2-fram-export-v1")
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: e.json))
    }

    func testPatchInfoTypes() {
        func types(_ raw: [UInt8]) -> (String, String) {
            let p = PatchInfoDecoded(raw: raw); return (p.sensorType, p.sensorTypePR67)
        }
        XCTAssertTrue(types([0x84, 0x0E, 0x30, 0x01, 0, 0]) == ("Unknown", "Libre 2"))
        XCTAssertTrue(types([0x55, 0x0E, 0x30, 0x01, 0, 0]) == ("Unknown", "Libre 2"))
        XCTAssertTrue(types([0x55, 0x0E, 0x39, 0x01, 0, 0]) == ("Unknown", "Unknown"))   // Gen2
        XCTAssertTrue(types([0x55, 0x0E, 0x30, 0x02, 0, 0]) == ("Unknown", "Unknown"))   // not EU
        XCTAssertTrue(types([0x76, 0x08, 0x30, 0x02, 0, 0]) == ("Libre 2 US", "Libre 2 US"))
        let libre3 = PatchInfoDecoded(raw: Array(repeating: 0xAB, count: 24))
        XCTAssertTrue(libre3.isLibre3)
        XCTAssertEqual(libre3.summary, "Libre 3")
    }

    func testOldSavedScansStillLoad() throws {
        // 1.1 saved scans without patchInfoError
        let old = #"[{"uid":[1,2,3,4,5,6,7,224],"patchInfo":[],"framEncrypted":[],"scannedAt":0,"#
            + #""tag":{"icManufacturerCode":7,"icSerialNumber":[1,2,3,4,5,6]}}]"#
        let scans = try JSONDecoder().decode([ScanResult].self, from: Data(old.utf8))
        XCTAssertEqual(scans.count, 1)
        XCTAssertNil(scans[0].patchInfoError)
    }

    func testOutOfRangeGlucoseIsNotAReading() throws {
        // every record's glucose is either nil or within (0, 500] mg/dL
        let p = try XCTUnwrap(makeExport(demo).parsed)
        for r in p.trend + p.history {
            if let g = r.glucose { XCTAssertTrue(g > 0 && g <= 500) }
        }
    }
}
