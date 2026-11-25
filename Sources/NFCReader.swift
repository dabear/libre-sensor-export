//  NFCReader.swift — read UID, patch info, and the 344-byte FRAM from a Libre 2 over NFC.
//  ISO 15693. Gen1 Libre 2 FRAM reads with a standard readMultipleBlocks; Gen2 (authenticated)
//  is detected and reported but not read here (its FRAM needs the authenticated pairing flow).
import Foundation
import CoreNFC

struct ScanResult {
    let uid: [UInt8]
    let patchInfo: [UInt8]
    let framEncrypted: [UInt8]   // 344 bytes, as read (Gen1 Libre 2 = encrypted)
}

final class NFCReader: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    @Published var status = "Hold the sensor to the top of your phone after tapping Scan."
    @Published var scanning = false
    @Published var result: ScanResult?
    @Published var errorText: String?

    private var session: NFCTagReaderSession?

    func scan() {
        guard NFCTagReaderSession.readingAvailable else {
            errorText = "NFC not available on this device."
            return
        }
        result = nil; errorText = nil; scanning = true
        session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: nil)
        session?.alertMessage = "Hold the sensor to the top of your phone."
        session?.begin()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        DispatchQueue.main.async {
            self.scanning = false
            if self.result == nil { self.errorText = error.localizedDescription }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard case let .iso15693(tag) = tags.first else {
            session.invalidate(errorMessage: "Not an ISO 15693 tag."); return
        }
        session.connect(to: tags.first!) { [weak self] error in
            guard let self else { return }
            if let error { session.invalidate(errorMessage: error.localizedDescription); return }

            let uid = [UInt8](tag.identifier.reversed())   // little-endian, as the crypto expects
            // Patch info: custom command 0xA1, empty parameters.
            tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                              customRequestParameters: Data()) { patch, error in
                if let error { session.invalidate(errorMessage: "patch info: \(error.localizedDescription)"); return }
                let patchInfo = [UInt8](patch)

                if Libre2FRAM.securityGeneration(patchInfo) == 2 {
                    // Gen2: report identity, but the FRAM read needs the authenticated flow.
                    DispatchQueue.main.async {
                        self.scanning = false
                        self.result = ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: [])
                        self.status = "Gen2 sensor — captured UID + patch info (FRAM needs authenticated read)."
                    }
                    session.alertMessage = "Done (Gen2 identity captured)."
                    session.invalidate()
                    return
                }

                self.readFRAM(tag: tag, session: session) { fram in
                    guard let fram, fram.count == 344 else {
                        session.invalidate(errorMessage: "FRAM read incomplete."); return
                    }
                    DispatchQueue.main.async {
                        self.scanning = false
                        self.result = ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: fram)
                        self.status = "Scan complete."
                    }
                    session.alertMessage = "Sensor read."
                    session.invalidate()
                }
            }
        }
    }

    /// Read 43 FRAM blocks (8 bytes each) with readMultipleBlocks, 3 blocks per request.
    private func readFRAM(tag: NFCISO15693Tag, session: NFCTagReaderSession,
                          completion: @escaping ([UInt8]?) -> Void) {
        let blocks = 43, per = 3
        var data = [UInt8](repeating: 0, count: blocks * 8)
        func readChunk(_ first: Int) {
            if first >= blocks { completion(data); return }
            let count = min(per, blocks - first)
            tag.readMultipleBlocks(requestFlags: .highDataRate,
                                   blockRange: NSRange(location: first, length: count)) { pages, error in
                if let error { session.invalidate(errorMessage: "block \(first): \(error.localizedDescription)"); completion(nil); return }
                var ok = true
                for (j, page) in pages.enumerated() {
                    let bytes = [UInt8](page)
                    guard bytes.count == 8 else { ok = false; break }
                    for k in 0..<8 { data[(first + j) * 8 + k] = bytes[k] }
                }
                if !ok { completion(nil); return }
                readChunk(first + count)
            }
        }
        readChunk(0)
    }
}
