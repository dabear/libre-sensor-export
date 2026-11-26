//  NFCReader.swift — read UID, patch info, and the 344-byte FRAM from a Libre sensor over NFC.
//  ISO 15693. Libre 1 and Gen1 Libre 2 FRAM reads with a standard readMultipleBlocks; Gen2
//  (authenticated) and Libre 3 are detected and reported but their memory isn't read here.
//
//  The read runs as one async function off the main actor; only its outcome is published on the
//  main actor. Each session has its own delegate and ID, so callbacks from an earlier session
//  can't touch the scan that's running now.
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

@MainActor
final class NFCReader: ObservableObject {
    static let readyText = "Tap Scan, then hold the top of your iPhone against the sensor."
    @Published var status = NFCReader.readyText
    @Published var scanning = false
    @Published var result: ScanResult?
    @Published var errorText: String?
    /// Also read the memory after the 43 FRAM blocks (slower; set before scan()).
    var deepScan = false

    private var session: NFCTagReaderSession?
    private var delegate: SessionDelegate?
    private var currentID: ObjectIdentifier?

    func scan() {
        guard NFCTagReaderSession.readingAvailable else {
            errorText = "This iPhone can't read NFC tags."
            return
        }
        result = nil; errorText = nil; scanning = true
        status = Self.readyText
        let delegate = SessionDelegate(reader: self, deep: deepScan)
        guard let session = NFCTagReaderSession(pollingOption: .iso15693, delegate: delegate, queue: nil) else {
            scanning = false; errorText = "Couldn't start NFC. Try again."
            return
        }
        self.delegate = delegate
        self.session = session
        currentID = ObjectIdentifier(session)
        session.alertMessage = "Hold the top of your iPhone against the sensor."
        session.begin()
    }

    fileprivate func finished(_ outcome: Outcome, session id: ObjectIdentifier) {
        guard id == currentID else { return }
        switch outcome {
        case .done(let r, let status):
            result = r; self.status = status; errorText = nil
        case .failed(let message):
            if let message { errorText = message }
        }
    }

    fileprivate func invalidated(_ id: ObjectIdentifier, message: String?) {
        guard id == currentID else { return }   // a late callback from an earlier session
        scanning = false
        if result == nil, errorText == nil { errorText = message }
        session = nil; delegate = nil
    }

    // MARK: - The read (off the main actor)

    fileprivate enum Outcome: Sendable {
        case done(ScanResult, status: String)
        case failed(String?)   // nil: the session's own end message says it
    }

    fileprivate nonisolated static func read(_ tag: NFCISO15693Tag, session: NFCTagReaderSession,
                                             deep: Bool) async -> Outcome {
        do {
            try await session.connect(to: .iso15693(tag))
        } catch {
            return fail(session, error)
        }
        let uid = [UInt8](tag.identifier.reversed())   // little-endian, as the crypto expects

        // Patch info: custom command 0xA1, empty parameters. Some Libre 1 don't answer it.
        var patchInfo: [UInt8] = [], patchError: String?
        do {
            let data = try await attempt(3) {
                try await tag.customCommand(requestFlags: .highDataRate, customCommandCode: 0xA1,
                                            customRequestParameters: Data())
            }
            patchInfo = [UInt8](data)
        } catch {
            if isFinal(error) { return fail(session, error) }
            patchError = error.localizedDescription
        }
        let decoded = PatchInfoDecoded(raw: patchInfo)

        if decoded.isLibre3 || decoded.generation == 2 {
            // Identity only: Libre 3 doesn't expose its memory over NFC, and a Gen2's FRAM needs
            // the authenticated read.
            let info = await tagInfo(tag, session: session, deep: false)
            session.alertMessage = "Patch info captured."
            session.invalidate()
            return .done(ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: [], tag: info,
                                    scannedAt: Date(), patchInfoError: patchError),
                         status: decoded.isLibre3 ? "Libre 3: patch info captured; its memory can't be read over NFC."
                                                  : "Gen2 sensor: patch info captured; its memory needs an authenticated read.")
        }

        // 43 FRAM blocks of 8 bytes, 3 per request, each request tried up to 3 times.
        let blocks = FRAMLayout.blocks
        var fram = [UInt8]()
        fram.reserveCapacity(blocks * 8)
        var first = 0
        while first < blocks {
            session.alertMessage = "Reading sensor… \(first * 100 / blocks)%"
            let count = min(3, blocks - first)
            do {
                let pages = try await attempt(3) {
                    let pages = try await tag.readMultipleBlocks(requestFlags: .highDataRate,
                                                                 blockRange: NSRange(location: first, length: count))
                    guard pages.count == count, pages.allSatisfy({ $0.count == 8 }) else { throw Incomplete() }
                    return pages
                }
                for page in pages { fram += [UInt8](page) }
                first += count
            } catch is Incomplete {
                let message = "Block \(first) came back incomplete. Hold still and scan again."
                session.invalidate(errorMessage: message)
                return .failed(message)
            } catch {
                return fail(session, error)
            }
        }
        // Scan time = when the FRAM was read, so ages and dates line up with it.
        let scannedAt = Date()
        let info = await tagInfo(tag, session: session, deep: deep)
        session.alertMessage = "Sensor read."
        session.invalidate()
        return .done(ScanResult(uid: uid, patchInfo: patchInfo, framEncrypted: fram, tag: info,
                                scannedAt: scannedAt, patchInfoError: patchError),
                     status: "Scan complete.")
    }

    private struct Incomplete: Error {}

    /// Tag manufacturer and serial, Get System Info, block lock status, and (deep) the memory after
    /// the FRAM. All best effort: a sensor that rejects one still gives a complete scan.
    private nonisolated static func tagInfo(_ tag: NFCISO15693Tag, session: NFCTagReaderSession,
                                            deep: Bool) async -> TagInfo {
        var info = TagInfo(icManufacturerCode: tag.icManufacturerCode,
                           icSerialNumber: [UInt8](tag.icSerialNumber))
        session.alertMessage = "Reading chip info…"
        do {
            let s = try await tag.systemInfo(requestFlags: .highDataRate)
            info.systemInfo = TagSystemInfo(dsfid: s.dataStorageFormatIdentifier,
                                            afi: s.applicationFamilyIdentifier,
                                            blockSize: s.blockSize, totalBlocks: s.totalBlocks,
                                            icReference: s.icReference)
        } catch {
            info.systemInfoError = error.localizedDescription
        }
        let total = info.systemInfo.map(\.totalBlocks).flatMap { $0 > 0 ? $0 : nil }

        // Block security status, 64 blocks per request.
        var statuses: [Int] = []
        let count = min(total ?? 43, 256)
        var first = 0
        while first < count {
            let n = min(64, count - first)
            do {
                statuses += try await securityStatus(tag, NSRange(location: first, length: n))
                first += n
            } catch {
                info.blockSecurityError = statuses.isEmpty ? error.localizedDescription
                                                           : "from block \(first): \(error.localizedDescription)"
                break
            }
        }
        info.blockSecurity = statuses.isEmpty ? nil : statuses

        if deep {
            // Libre 1 memory is 244 blocks; use the tag's own count when it gave one.
            let (bytes, note) = await extraMemory(tag, session: session, end: min(total ?? 244, 256))
            info.extraMemory = bytes
            info.extraMemoryNote = note
        }
        return info
    }

    private nonisolated static func securityStatus(_ tag: NFCISO15693Tag, _ range: NSRange) async throws -> [Int] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<[Int], Error>) in
            tag.getMultipleBlockSecurityStatus(requestFlags: .highDataRate, blockRange: range) { status, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: status.map(\.intValue)) }
            }
        }
    }

    /// Blocks 43..<end, 8 per request; where a request fails, one block at a time to find the
    /// first block the sensor won't give.
    private nonisolated static func extraMemory(_ tag: NFCISO15693Tag, session: NFCTagReaderSession,
                                                end: Int) async -> ([UInt8], String) {
        let start = FRAMLayout.blocks
        guard end > start else { return ([], "the chip has no blocks after 42") }
        var bytes: [UInt8] = []
        var first = start
        while first < end {
            session.alertMessage = "Reading all memory… \((first - start) * 100 / (end - start))%"
            let n = min(8, end - first)
            if let pages = try? await tag.readMultipleBlocks(requestFlags: .highDataRate,
                                                             blockRange: NSRange(location: first, length: n)),
               pages.count == n {
                for page in pages { bytes += [UInt8](page) }
                first += n
                continue
            }
            do {
                let page = try await attempt(2) {
                    try await tag.readMultipleBlocks(requestFlags: .highDataRate,
                                                     blockRange: NSRange(location: first, length: 1))
                }
                guard let p = page.first else { throw Incomplete() }
                bytes += [UInt8](p)
                first += 1
            } catch {
                let read = first == start ? "" : "blocks \(start)–\(first - 1) read; "
                return (bytes, read + stopReason(error, block: first))
            }
        }
        return (bytes, "all of blocks \(start)–\(end - 1) read")
    }

    private nonisolated static func stopReason(_ error: Error, block: Int) -> String {
        switch (error as? NFCReaderError)?.code {
        case .readerTransceiveErrorTagConnectionLost?: return "connection lost at block \(block)"
        case .readerTransceiveErrorTagResponseError?: return "block \(block) refused by the sensor"
        case .readerSessionInvalidationErrorSessionTimeout?, .readerTransceiveErrorSessionInvalidated?:
            return "the NFC session ended at block \(block)"
        default: return "stopped at block \(block): \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    /// Ends the session with a message (unless it has already ended) and reports the failure.
    private nonisolated static func fail(_ session: NFCTagReaderSession, _ error: Error) -> Outcome {
        if sessionIsOver(error) { return .failed(nil) }   // didInvalidate brings the message
        let message = describe(error) ?? "The read was cut short. Hold still and scan again."
        session.invalidate(errorMessage: message)
        return .failed(message)
    }

    /// Tries `op` up to `times` times; errors that end the connection or the session aren't retried.
    private nonisolated static func attempt<T>(_ times: Int, _ op: () async throws -> T) async throws -> T {
        var last: Error = Incomplete()
        for _ in 0..<times {
            do { return try await op() } catch {
                last = error
                if isFinal(error) { throw error }
            }
        }
        throw last
    }

    /// The tag or the session is gone: retrying can't help.
    nonisolated static func isFinal(_ error: Error) -> Bool {
        guard let code = (error as? NFCReaderError)?.code else { return false }
        return code == .readerTransceiveErrorTagConnectionLost || code == .readerTransceiveErrorTagNotConnected
            || sessionIsOver(error)
    }

    /// The session itself has ended (cancelled, timed out, invalidated).
    nonisolated static func sessionIsOver(_ error: Error) -> Bool {
        guard let code = (error as? NFCReaderError)?.code else { return false }
        return [.readerTransceiveErrorSessionInvalidated, .readerSessionInvalidationErrorUserCanceled,
                .readerSessionInvalidationErrorSessionTimeout,
                .readerSessionInvalidationErrorSessionTerminatedUnexpectedly].contains(code)
    }

    /// A message people can act on, or nil when they cancelled themselves.
    nonisolated static func describe(_ error: Error) -> String? {
        guard let e = error as? NFCReaderError else { return error.localizedDescription }
        switch e.code {
        case .readerSessionInvalidationErrorUserCanceled:
            return nil
        case .readerSessionInvalidationErrorSessionTimeout:
            return "Timed out. Tap Scan, then hold the top of the iPhone flat against the sensor."
        case .readerSessionInvalidationErrorSystemIsBusy:
            return "NFC is busy. Close other apps that scan sensors and try again."
        case .readerTransceiveErrorTagConnectionLost, .readerTransceiveErrorTagNotConnected:
            return "Lost the sensor mid-read. Hold the iPhone still against the sensor and scan again."
        case .readerTransceiveErrorRetryExceeded, .readerTransceiveErrorTagResponseError:
            return "The sensor didn't answer properly. Move the iPhone slightly and scan again."
        default:
            return e.localizedDescription
        }
    }
}

/// CoreNFC objects aren't Sendable; each is only used by one session's read, one step at a time.
private struct Unchecked<T>: @unchecked Sendable { let value: T }

/// One per session, so a session's callbacks always know which scan they belong to.
private final class SessionDelegate: NSObject, NFCTagReaderSessionDelegate, @unchecked Sendable {
    private weak var reader: NFCReader?
    private let deep: Bool

    init(reader: NFCReader, deep: Bool) {
        self.reader = reader
        self.deep = deep
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let id = ObjectIdentifier(session), message = NFCReader.describe(error)
        Task { @MainActor [weak reader] in reader?.invalidated(id, message: message) }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        let id = ObjectIdentifier(session)
        guard let first = tags.first, case let .iso15693(tag) = first else {
            session.invalidate(errorMessage: "That isn't a Libre sensor (not an ISO 15693 tag).")
            return
        }
        let boxed = Unchecked(value: (tag, session)), deep = self.deep
        Task { [weak reader] in
            let outcome = await NFCReader.read(boxed.value.0, session: boxed.value.1, deep: deep)
            await reader?.finished(outcome, session: id)
        }
    }
}
