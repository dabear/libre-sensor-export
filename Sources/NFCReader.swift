//  NFCReader.swift — read UID, patch info, and the 344-byte FRAM from a Libre sensor over NFC.
//  ISO 15693. Libre 1 and Gen1 Libre 2 FRAM reads with a standard readMultipleBlocks; Gen2
//  (authenticated) and Libre 3 are detected and reported but their memory isn't read here.
import Foundation
import CoreNFC

struct ScanResult: Codable, Identifiable {
    let uid: [UInt8]
    let patchInfo: [UInt8]       // empty when the sensor didn't answer (some Libre 1)
    let framEncrypted: [UInt8]   // 344 bytes as read (encrypted on a Libre 2); empty when not read
    let tag: TagInfo
    let scannedAt: Date
    var patchInfoError: String? = nil
    var id: Date { scannedAt }
}

final class NFCReader: NSObject, ObservableObject, NFCTagReaderSessionDelegate {
    static let readyText = "Tap Scan, then hold the top of your iPhone against the sensor."
    @Published var status = NFCReader.readyText
    @Published var scanning = false
    @Published var result: ScanResult?
    @Published var errorText: String?
    /// Also read the memory after the 43 FRAM blocks (slower; set before scan()).
    var deepScan = false

    private var session: NFCTagReaderSession?
    /// Our own message for the failure that ends the session (the delegate only gets "cancelled").
    private var pendingError: String?

    func scan() {
        guard NFCTagReaderSession.readingAvailable else {
            errorText = "This iPhone can't read NFC tags."
            return
        }
        result = nil; errorText = nil; pendingError = nil; scanning = true
        status = Self.readyText
        session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: nil)
        session?.alertMessage = "Hold the top of your iPhone against the sensor."
        session?.begin()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let message = pendingError ?? Self.describe(error)
        DispatchQueue.main.async {
            self.scanning = false
            if self.result == nil { self.errorText = message }
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let first = tags.first, case let .iso15693(tag) = first else {
            fail(session, "That isn't a Libre sensor (not an ISO 15693 tag)."); return
        }
        session.connect(to: first) { [weak self] error in
            guard let self else { return }
            if let error { self.fail(session, Self.describe(error) ?? error.localizedDescription); return }

            let uid = [UInt8](tag.identifier.reversed())   // little-endian, as the crypto expects
            // Patch info: custom command 0xA1, empty parameters. Some Libre 1 don't answer it.
            self.retry({ done in
                tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                  customRequestParameters: Data()) { data, error in done(error == nil ? data : nil, error) }
            }) { patch, error in
                if Self.isConnectionLost(error) {
                    self.fail(session, Self.describe(error!) ?? "Lost the sensor."); return
                }
                let patchInfo = patch.map { [UInt8]($0) } ?? []
                let patchError = patch == nil ? (error?.localizedDescription ?? "no answer") : nil
                let decoded = PatchInfoDecoded(raw: patchInfo)

                if decoded.isLibre3 || decoded.generation == 2 {
                    // Identity only: Libre 3 doesn't expose its memory over NFC, and a Gen2's
                    // FRAM needs the authenticated read.
                    self.readTagInfo(tag, session: session, deep: false) { info in
                        let r = ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: [], tag: info,
                                           scannedAt: Date(), patchInfoError: patchError)
                        self.finish(session, r,
                                    status: decoded.isLibre3 ? "Libre 3: patch info captured; its memory can't be read over NFC."
                                                             : "Gen2 sensor: patch info captured; its memory needs an authenticated read.",
                                    alert: "Patch info captured.")
                    }
                    return
                }

                self.readFRAM(tag: tag, session: session) { fram, failure in
                    guard let fram else { self.fail(session, failure ?? "The read was cut short. Hold still and scan again."); return }
                    // Scan time = when the FRAM was read, so ages and dates line up with it.
                    let scannedAt = Date()
                    self.readTagInfo(tag, session: session, deep: self.deepScan) { info in
                        let r = ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: fram, tag: info,
                                           scannedAt: scannedAt, patchInfoError: patchError)
                        self.finish(session, r, status: "Scan complete.", alert: "Sensor read.")
                    }
                }
            }
        }
    }

    // MARK: - Steps

    /// Read 43 FRAM blocks (8 bytes each), 3 per request, retrying each request twice.
    private func readFRAM(tag: NFCISO15693Tag, session: NFCTagReaderSession,
                          completion: @escaping ([UInt8]?, String?) -> Void) {
        let blocks = 43, per = 3
        var data = [UInt8](repeating: 0, count: blocks * 8)
        func chunk(_ first: Int, tries: Int) {
            if first >= blocks { completion(data, nil); return }
            session.alertMessage = "Reading sensor… \(first * 100 / blocks)%"
            let count = min(per, blocks - first)
            tag.readMultipleBlocks(requestFlags: .highDataRate,
                                   blockRange: NSRange(location: first, length: count)) { pages, error in
                let complete = error == nil && pages.count == count && pages.allSatisfy { $0.count == 8 }
                guard complete else {
                    if tries < 2, !Self.isConnectionLost(error) { chunk(first, tries: tries + 1); return }
                    completion(nil, error.flatMap(Self.describe) ?? "Block \(first) came back incomplete. Hold still and scan again.")
                    return
                }
                for (j, page) in pages.enumerated() {
                    for (k, byte) in page.enumerated() { data[(first + j) * 8 + k] = byte }
                }
                chunk(first + count, tries: 0)
            }
        }
        chunk(0, tries: 0)
    }

    /// Tag manufacturer and serial, Get System Info, block lock status, and (deep) the memory
    /// after the FRAM. All best effort: a sensor that rejects one still gives a complete scan.
    private func readTagInfo(_ tag: NFCISO15693Tag, session: NFCTagReaderSession, deep: Bool,
                             completion: @escaping (TagInfo) -> Void) {
        var info = TagInfo(icManufacturerCode: tag.icManufacturerCode,
                           icSerialNumber: [UInt8](tag.icSerialNumber))
        session.alertMessage = "Reading chip info…"
        tag.getSystemInfo(requestFlags: .highDataRate) { result in
            switch result {
            case .success(let s):
                info.systemInfo = TagSystemInfo(dsfid: s.dataStorageFormatIdentifier,
                                                afi: s.applicationFamilyIdentifier,
                                                blockSize: s.blockSize, totalBlocks: s.totalBlocks,
                                                icReference: s.icReference)
            case .failure(let error):
                info.systemInfoError = error.localizedDescription
            }
            let total = info.systemInfo.map(\.totalBlocks).flatMap { $0 > 0 ? $0 : nil }
            self.readBlockSecurity(tag, count: min(total ?? 43, 256)) { statuses, error in
                info.blockSecurity = statuses.isEmpty ? nil : statuses
                info.blockSecurityError = error
                guard deep else { completion(info); return }
                // Libre 1 memory is 244 blocks; use the tag's own count when it gave one.
                self.readExtra(tag, session: session, end: min(total ?? 244, 256)) { bytes, note in
                    info.extraMemory = bytes
                    info.extraMemoryNote = note
                    completion(info)
                }
            }
        }
    }

    private func readBlockSecurity(_ tag: NFCISO15693Tag, count: Int,
                                   completion: @escaping ([Int], String?) -> Void) {
        var statuses: [Int] = []
        func chunk(_ first: Int) {
            if first >= count { completion(statuses, nil); return }
            let n = min(64, count - first)
            tag.getMultipleBlockSecurityStatus(requestFlags: .highDataRate,
                                               blockRange: NSRange(location: first, length: n)) { status, error in
                if let error {
                    completion(statuses, statuses.isEmpty ? error.localizedDescription
                                                          : "from block \(first): \(error.localizedDescription)")
                    return
                }
                statuses += status.map(\.intValue)
                chunk(first + n)
            }
        }
        chunk(0)
    }

    /// Blocks 43..<end, stopping at the first block the sensor refuses.
    private func readExtra(_ tag: NFCISO15693Tag, session: NFCTagReaderSession, end: Int,
                           completion: @escaping ([UInt8], String) -> Void) {
        let start = 43
        var bytes: [UInt8] = []
        func chunk(_ first: Int, tries: Int) {
            if first >= end { completion(bytes, "all of blocks \(start)–\(end - 1) read"); return }
            session.alertMessage = "Reading all memory… \((first - start) * 100 / max(end - start, 1))%"
            tag.readMultipleBlocks(requestFlags: .highDataRate,
                                   blockRange: NSRange(location: first, length: 1)) { pages, error in
                if let page = pages.first, error == nil {
                    bytes += [UInt8](page)
                    chunk(first + 1, tries: 0)
                } else if tries < 1, !Self.isConnectionLost(error) {
                    chunk(first, tries: tries + 1)
                } else {
                    let why = error?.localizedDescription ?? "no data"
                    completion(bytes, first == start ? "block \(start) refused: \(why)"
                                                     : "blocks \(start)–\(first - 1) read; block \(first) refused: \(why)")
                }
            }
        }
        chunk(start, tries: 0)
    }

    // MARK: - Helpers

    private func finish(_ session: NFCTagReaderSession, _ result: ScanResult, status: String, alert: String) {
        DispatchQueue.main.async {
            self.result = result
            self.status = status
            self.scanning = false
        }
        session.alertMessage = alert
        session.invalidate()
    }

    private func fail(_ session: NFCTagReaderSession, _ message: String) {
        pendingError = message
        session.invalidate(errorMessage: message)
    }

    /// Runs `op` up to 3 times until it returns a value.
    private func retry<T>(_ op: @escaping (@escaping (T?, Error?) -> Void) -> Void, attempts: Int = 3,
                          done: @escaping (T?, Error?) -> Void) {
        op { value, error in
            if value != nil || attempts <= 1 || Self.isConnectionLost(error) { done(value, error) }
            else { self.retry(op, attempts: attempts - 1, done: done) }
        }
    }

    private static func isConnectionLost(_ error: Error?) -> Bool {
        (error as? NFCReaderError)?.code == .readerTransceiveErrorTagConnectionLost
    }

    /// A message people can act on, or nil when they cancelled themselves.
    static func describe(_ error: Error) -> String? {
        guard let e = error as? NFCReaderError else { return error.localizedDescription }
        switch e.code {
        case .readerSessionInvalidationErrorUserCanceled:
            return nil
        case .readerSessionInvalidationErrorSessionTimeout:
            return "Timed out. Tap Scan, then hold the top of the iPhone flat against the sensor."
        case .readerSessionInvalidationErrorSystemIsBusy:
            return "NFC is busy. Close other apps that scan sensors and try again."
        case .readerTransceiveErrorTagConnectionLost:
            return "Lost the sensor mid-read. Hold the iPhone still against the sensor and scan again."
        case .readerTransceiveErrorRetryExceeded, .readerTransceiveErrorTagResponseError:
            return "The sensor didn't answer properly. Move the iPhone slightly and scan again."
        default:
            return e.localizedDescription
        }
    }
}
