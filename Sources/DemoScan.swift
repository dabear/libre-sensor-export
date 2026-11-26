//  DemoScan.swift — a made-up sensor for screenshots and UI work in the Simulator, which
//  has no NFC. Debug builds only: launch with the argument `-demo`. The UID, patch info
//  and readings are synthetic (built with this app's own parser), not from a real sensor.
#if DEBUG
import Foundation

enum DemoScan {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    static func result() -> ScanResult {
        let uid: [UInt8] = [0x5A, 0x3C, 0x91, 0x27, 0x00, 0xA0, 0x07, 0xE0]
        return ScanResult(
            uid: uid,
            patchInfo: [0x84, 0x0E, 0x30, 0x01, 0x4B, 0x2E],  // a "303" Libre 2 EU, as in LibreTransmitter#67
            framEncrypted: bytes(framHex),
            tag: TagInfo(icManufacturerCode: 0x07, icSerialNumber: Array(uid[0..<6].reversed()),
                         systemInfo: nil, systemInfoError: "demo data"),
            scannedAt: Date())
    }

    private static func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](), chars = Array(hex)
        for i in stride(from: 0, to: chars.count, by: 2) { out.append(UInt8(String(chars[i...i + 1]), radix: 16)!) }
        return out
    }

    // 344 bytes, encrypted as a Libre 2 would return them.
    private static let framHex = "2fe83e1bd645478cedb503c655986a1093a9bc1124fe4740c9b9582b092f61b5724237e4ae1143bdb77b9a9c66fa2339113f2a13c29cd731f42fee4f9a4f5b0c5e338bc0e471b75c3c1ea26bc10dd29e4d5ac2bc7f33f0961db385befafacd9bb3f73531569c3193ae9693114377884f0b8aff9e3d497f1f359ae19a62c2292244de9b4dc1fc0b2a6340c9a15167e0cedf04792e960170c6bed56456b1405a3377c963d9cf7ec363dda816a1b8cdcebfacec637676f3ecb784a4b772fb20b5d237e007fd5b464dda81cdc80e6062e9181ed191811e5c3e487f60098361cd281d0e244754eaf30a15131cc32c2218b3906d5973a3a27e9e99884997ffdead12a40d55d270a093ddf43e00a2f33b4f1d304f4403255e703f38dbb2f15eaaf91594aef741d12e9f3b9db396c5f113748241248a8b7e6d4a7c11289a957a0fd62374a33c25ac91a7ce6aefab035e74dba5be85b9ba89059109d0"
}
#endif
