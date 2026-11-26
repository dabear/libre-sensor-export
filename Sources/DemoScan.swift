//  DemoScan.swift — a made-up sensor for screenshots and UI work in the Simulator, which
//  has no NFC. Debug builds only: launch with the argument `-demo`. The UID, patch info
//  and readings are synthetic (built with this app's own parser), not from a real sensor.
#if DEBUG
import Foundation

enum DemoScan {
    static var isOn: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }

    /// `-demoSaved`: show it as a saved scan. `-demoBadCRC`: one body byte corrupted, as when a read
    /// overlaps the sensor's once-a-minute memory update.
    static var saved: Bool { ProcessInfo.processInfo.arguments.contains("-demoSaved") }
    static var badCRC: Bool { ProcessInfo.processInfo.arguments.contains("-demoBadCRC") }

    /// `-demoTab readings` / `-demoTab technical` opens that tab (for screenshots).
    static var tab: ScanTab? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demoTab"), i + 1 < args.count else { return nil }
        return ScanTab(rawValue: args[i + 1].capitalized)
    }

    static func result() -> ScanResult {
        let uid: [UInt8] = [0x5A, 0x3C, 0x91, 0x27, 0x00, 0xA0, 0x07, 0xE0]
        return ScanResult(
            uid: uid,
            patchInfo: [0x84, 0x0E, 0x30, 0x01, 0x4B, 0x2E],  // a "303" Libre 2 EU, as in LibreTransmitter#67
            framEncrypted: { var b = bytes(framHex); if badCRC { b[100] ^= 0x5A }; return b }(),
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
    private static let framHex = "2fe83e1bd645478cedb503c655986a1093a9bc1124fe4740224c582b072f61b5724238e4ae1143bdb87b9a9c66fa2c39113f2a13ce9cd731f42fe14f9a4f5b0c51338bc0e471a75c3c1ea26bd30dd29e4d5acebc7f33f09611b385befafac79bb3f735315f9c3193ae969a114377884f068aff9e3d49731f359ae19a71c2292244dee84dc1fc0b2a1240c9a15167f3cedf04792e830170c6bed57156b1405a3360c963d9cf7ecb63dda816a1becdcebfacec677676f3ecb780a4b772fb20b2d237e007fd5e464dda81cdcd0e6062e9181ad191811e5c3b487f6009836fcd281d0e244f54eaf30a15e51dc32c221847916d5973a3ac7e9e99884984ffdead12a41b55d270a093e9f43e00a2f3254f1d304f4417255e703f382db3f15eaaf9e295aef741d13e9f3b9db396ebf113748241168a8b7e6d4a6a11289a957a0fd62374a33c25ac91a7ce6aefab035e74dba5be85b9ba89059109d0"
}
#endif
