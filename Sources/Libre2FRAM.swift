//  Libre2FRAM.swift — self-contained Libre 2 NFC FRAM decrypt + parse.
//  Ported faithfully from LoopKit/LibreTransmitter (MIT): PreLibre2.swift,
//  SensorData.swift, CRC.swift, Measurement.swift. No Abbott binary involved.
import Foundation

enum Libre2FRAM {

    // MARK: Generation / type from patch info
    /// 2 = Gen2 (authenticated NFC, not handled here), 1 = Gen1 Libre 2 / US 14-day, 0 = other.
    static func securityGeneration(_ patchInfo: [UInt8]) -> Int {
        guard patchInfo.count >= 3 else { return 0 }
        let product = Int(patchInfo[2] >> 4), security = Int(patchInfo[2] & 0x0F)
        if product == 3 && security >= 9 { return 2 }
        if (product == 3 || product == 7) && security < 9 { return 1 }
        return 0
    }
    /// .libre2 for a type-3 patch, else .libreUS14day fallback for decrypt arg selection.
    static func isLibre2(_ patchInfo: [UInt8]) -> Bool {
        guard patchInfo.count >= 3 else { return false }
        return (patchInfo[2] >> 4) == 3
    }

    // MARK: Crypto (PreLibre2)
    private static let key: [UInt16] = [0xA0C5, 0x6860, 0x0000, 0x14C6]
    private static func u16(_ hi: UInt8, _ lo: UInt8) -> UInt16 { (UInt16(hi) << 8) | UInt16(lo) }

    private static func processCrypto(_ input: [UInt16]) -> [UInt16] {
        func op(_ v: UInt16) -> UInt16 {
            var r = v >> 2
            if v & 1 != 0 { r ^= key[1] }
            if v & 2 != 0 { r ^= key[0] }
            return r
        }
        let r0 = op(input[0]) ^ input[3]
        let r1 = op(r0) ^ input[2]
        let r2 = op(r1) ^ input[1]
        let r3 = op(r2) ^ input[0]
        let r4 = op(r3)
        let r5 = op(r4 ^ r0)
        let r6 = op(r5 ^ r1)
        let r7 = op(r6 ^ r2)
        return [r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4]
    }

    private static func prepareVariables(id: [UInt8], x: UInt16, y: UInt16) -> [UInt16] {
        let s1 = UInt16(truncatingIfNeeded: UInt(u16(id[5], id[4])) + UInt(x) + UInt(y))
        let s2 = UInt16(truncatingIfNeeded: UInt(u16(id[3], id[2])) + UInt(key[2]))
        let s3 = UInt16(truncatingIfNeeded: UInt(u16(id[1], id[0])) + UInt(x) * 2)
        let s4 = 0x241a ^ key[3]
        return [s1, s2, s3, s4]
    }

    /// Decrypt the 344-byte (43x8) Libre 2 FRAM read over NFC.
    static func decryptFRAM(id: [UInt8], info: [UInt8], data: [UInt8]) -> [UInt8]? {
        guard data.count >= 344, id.count >= 6, info.count >= 6 else { return nil }
        let libre2 = isLibre2(info)
        func arg(_ block: Int) -> UInt16 {
            if libre2 { return u16(info[5], info[4]) ^ 0x44 }
            if block < 3 || block >= 40 { return 0xcadc }       // US 14-day header/footer
            return u16(info[5], info[4])
        }
        var out = [UInt8]()
        out.reserveCapacity(344)
        for i in 0..<43 {
            let bk = processCrypto(prepareVariables(id: id, x: UInt16(i), y: arg(i)))
            for (j, half) in [bk[0], bk[0] >> 8, bk[1], bk[1] >> 8, bk[2], bk[2] >> 8, bk[3], bk[3] >> 8].enumerated() {
                out.append(data[i * 8 + j] ^ UInt8(truncatingIfNeeded: half))
            }
        }
        return out
    }

    // MARK: CRC
    private static let crc16table: [UInt16] = [0, 4489, 8978, 12955, 17956, 22445, 25910, 29887, 35912, 40385, 44890, 48851, 51820, 56293, 59774, 63735, 4225, 264, 13203, 8730, 22181, 18220, 30135, 25662, 40137, 36160, 49115, 44626, 56045, 52068, 63999, 59510, 8450, 12427, 528, 5017, 26406, 30383, 17460, 21949, 44362, 48323, 36440, 40913, 60270, 64231, 51324, 55797, 12675, 8202, 4753, 792, 30631, 26158, 21685, 17724, 48587, 44098, 40665, 36688, 64495, 60006, 55549, 51572, 16900, 21389, 24854, 28831, 1056, 5545, 10034, 14011, 52812, 57285, 60766, 64727, 34920, 39393, 43898, 47859, 21125, 17164, 29079, 24606, 5281, 1320, 14259, 9786, 57037, 53060, 64991, 60502, 39145, 35168, 48123, 43634, 25350, 29327, 16404, 20893, 9506, 13483, 1584, 6073, 61262, 65223, 52316, 56789, 43370, 47331, 35448, 39921, 29575, 25102, 20629, 16668, 13731, 9258, 5809, 1848, 65487, 60998, 56541, 52564, 47595, 43106, 39673, 35696, 33800, 38273, 42778, 46739, 49708, 54181, 57662, 61623, 2112, 6601, 11090, 15067, 20068, 24557, 28022, 31999, 38025, 34048, 47003, 42514, 53933, 49956, 61887, 57398, 6337, 2376, 15315, 10842, 24293, 20332, 32247, 27774, 42250, 46211, 34328, 38801, 58158, 62119, 49212, 53685, 10562, 14539, 2640, 7129, 28518, 32495, 19572, 24061, 46475, 41986, 38553, 34576, 62383, 57894, 53437, 49460, 14787, 10314, 6865, 2904, 32743, 28270, 23797, 19836, 50700, 55173, 58654, 62615, 32808, 37281, 41786, 45747, 19012, 23501, 26966, 30943, 3168, 7657, 12146, 16123, 54925, 50948, 62879, 58390, 37033, 33056, 46011, 41522, 23237, 19276, 31191, 26718, 7393, 3432, 16371, 11898, 59150, 63111, 50204, 54677, 41258, 45219, 33336, 37809, 27462, 31439, 18516, 23005, 11618, 15595, 3696, 8185, 63375, 58886, 54429, 50452, 45483, 40994, 37561, 33584, 31687, 27214, 22741, 18780, 15843, 11370, 7921, 3960]
    static func crc16(_ message: [UInt8], seed: UInt16 = 0xffff) -> UInt16 {
        var crc = seed
        for b in message { crc = (crc >> 8) ^ crc16table[Int((crc ^ UInt16(b)) & 0xFF)] }
        var rev: UInt16 = 0
        for _ in 0..<16 { rev = (rev << 1) | (crc & 1); crc >>= 1 }
        return rev.byteSwapped
    }
    static func crcCheck(_ region: ArraySlice<UInt8>) -> CRCCheck {
        let b = Array(region)
        return CRCCheck(stored: UInt16(b[0]) << 8 | UInt16(b[1]), computed: crc16(Array(b.dropFirst(2))))
    }

    // MARK: bit reader
    static func readBits(_ buf: [UInt8], _ byteOffset: Int, _ bitOffset: Int, _ bitCount: Int) -> Int {
        guard bitCount != 0 else { return 0 }
        var res = 0
        for i in 0..<bitCount {
            let t = byteOffset * 8 + bitOffset + i
            if t >= 0, (buf[t / 8] >> (t % 8)) & 1 == 1 { res |= (1 << i) }
        }
        return res
    }
}
