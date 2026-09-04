import Foundation
import UIKit
import CoreMedia
import VideoToolbox

/// Minimal RTSP client that pulls the H.264 live stream from the glasses
/// (`rtsp://192.168.43.1:554/live`), decodes frames with VideoToolbox and
/// exposes the most recent frame as a `UIImage` for the AI vision pipeline.
///
/// Deliberately minimal, single-purpose frame grabber:
/// - RTP/AVP/TCP (interleaved) transport only
/// - H.264 depacketization: single NAL, STAP-A and FU-A (RFC 6184)
/// - No audio, no recording, no seeking
///
/// The phone must already be joined to the glasses' Wi-Fi hotspot
/// (BLEManager -> HotspotManager) before the stream becomes reachable, so
/// `start()` keeps retrying the connection until the glasses' RTSP server
/// answers (it comes up a few seconds after the RTSP start command).
public final class RTSPClient: ObservableObject {

    public static let shared = RTSPClient()

    /// Default live stream URL of the glasses (confirmed by the 0x12 ack).
    public static let defaultURL = URL(string: "rtsp://192.168.43.1:554/live")!

    // MARK: - Published state (main thread only)

    /// True after the RTSP PLAY handshake succeeded.
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var statusMessage: String = "RTSP oprit"
    /// Total number of decoded frames since the session started.
    @Published public private(set) var framesDecoded: Int = 0
    /// Throttled (~2 fps) preview of the latest decoded frame, for the UI.
    @Published public private(set) var previewFrame: UIImage?

    // MARK: - Tuning

    private let connectTimeout: TimeInterval = 5.0
    private let retryDelay: TimeInterval = 3.0
    private let maxConnectionAttempts = 60
    private let keepaliveInterval: TimeInterval = 25.0
    private let previewInterval: TimeInterval = 0.5

    // MARK: - Session state

    private var baseURL: URL = RTSPClient.defaultURL
    private var setupURL: URL = RTSPClient.defaultURL

    private let lifecycleLock = NSLock()
    private var isStarted = false
    private var socketFD: Int32 = -1
    private var cSeq = 0

    private var sessionID: String?
    private var handshakeComplete = false

    private enum HandshakeStep { case options, describe, setup, play, streaming }
    private enum ParserMode { case rtspResponse, interleaved }
    private var handshakeStep: HandshakeStep = .options
    private var parserMode: ParserMode = .rtspResponse
    private var pendingData = Data()
    private let rtspDelimiter = Data("\r\n\r\n".utf8)

    private var keepaliveTimer: DispatchSourceTimer?

    // MARK: - H.264 assembly state (read thread only)

    private var spsData: Data?
    private var ppsData: Data?
    private var accessUnit: [Data] = []
    private var fuBuffer: Data?
    private var currentRTPTimestamp: UInt32 = 0

    // MARK: - VideoToolbox decoder

    private let decoderLock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?

    // MARK: - Latest frame storage

    private let frameLock = NSLock()
    private var _latestFrame: UIImage?
    private var _latestFrameAt: Date?
    private var lastPreviewPublish = Date.distantPast

    private init() {}

    // MARK: - Public API

    /// Starts the RTSP session (idempotent). Retries in the background until
    /// the glasses' RTSP server is reachable.
    public func start(url: URL = RTSPClient.defaultURL) {
        lifecycleLock.lock()
        let alreadyStarted = isStarted
        isStarted = true
        lifecycleLock.unlock()

        guard !alreadyStarted else {
            debugLog("start() ignored — RTSP session already running.")
            return
        }

        baseURL = url
        setupURL = url

        setMainStatus("RTSP: conectare...")
        debugLog("Starting RTSP session for \(url.absoluteString).")

        let thread = Thread { [weak self] in
            self?.sessionLoop()
        }
        thread.name = "RTSPClient.session"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Stops the session and releases the decoder (idempotent).
    public func stop() {
        lifecycleLock.lock()
        let wasStarted = isStarted
        isStarted = false
        let fd = socketFD
        lifecycleLock.unlock()

        guard wasStarted || fd >= 0 else { return }

        debugLog("Stopping RTSP session.")

        // Best-effort TEARDOWN so the glasses stop pushing the stream.
        if fd >= 0, handshakeComplete, let session = sessionID {
            let request = "TEARDOWN \(baseURL.absoluteString) RTSP/1.0\r\n" +
                "CSeq: \(nextCSeq())\r\n" +
                "User-Agent: SmartGlassesApp/1.0\r\n" +
                "Session: \(session)\r\n\r\n"
            let data = Data(request.utf8)
            data.withUnsafeBytes { raw in
                if let base = raw.baseAddress {
                    _ = send(fd, base, raw.count, 0)
                }
            }
        }

        // Unblocks the blocking recv; the session thread closes the fd.
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }

        stopKeepalive()

        DispatchQueue.main.async {
            self.isStreaming = false
            self.statusMessage = "RTSP oprit"
            self.previewFrame = nil
        }

        teardownDecoder()
        frameLock.lock()
        _latestFrame = nil
        _latestFrameAt = nil
        frameLock.unlock()
    }

    /// Returns the most recent decoded frame, or nil if none exists or the
    /// frame is older than `maxAge` (the stream probably stalled).
    public func captureLatestFrame(maxAge: TimeInterval = 5.0) -> UIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        guard let frame = _latestFrame else { return nil }
        if let date = _latestFrameAt, Date().timeIntervalSince(date) > maxAge {
            return nil
        }
        return frame
    }

    deinit {
        lifecycleLock.lock()
        let fd = socketFD
        socketFD = -1
        isStarted = false
        lifecycleLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        teardownDecoder()
    }

    // MARK: - Session loop (background thread)

    private func sessionLoop() {
        var consecutiveFailures = 0

        while true {
            lifecycleLock.lock()
            let shouldRun = isStarted
            lifecycleLock.unlock()
            guard shouldRun else { break }

            let didStream = runSession()

            lifecycleLock.lock()
            let keepGoing = isStarted
            lifecycleLock.unlock()
            guard keepGoing else { break }

            if didStream {
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
            }

            guard consecutiveFailures < maxConnectionAttempts else {
                lifecycleLock.lock()
                isStarted = false
                lifecycleLock.unlock()
                setMainStatus("RTSP: eșuat după \(maxConnectionAttempts) încercări")
                debugLog("RTSP connection failed after \(maxConnectionAttempts) attempts — giving up.", level: .error)
                break
            }

            if !didStream {
                setMainStatus("RTSP: reîncercare în \(Int(retryDelay))s...")
            }
            Thread.sleep(forTimeInterval: retryDelay)
        }
    }

    /// One connect -> handshake -> stream attempt. Returns true if the
    /// session reached the streaming state.
    private func runSession() -> Bool {
        // Reset per-session state.
        pendingData = Data()
        parserMode = .rtspResponse
        handshakeStep = .options
        handshakeComplete = false
        sessionID = nil
        accessUnit.removeAll()
        fuBuffer = nil

        let host = baseURL.host ?? "192.168.43.1"
        let port = UInt16(baseURL.port ?? 554)

        guard let fd = openSocket(host: host, port: port, timeout: connectTimeout) else {
            setMainStatus("RTSP: conexiune eșuată")
            debugLog("TCP connect to \(host):\(port) failed.", level: .error)
            return false
        }

        lifecycleLock.lock()
        socketFD = fd
        lifecycleLock.unlock()

        debugLog("TCP connected to \(host):\(port) — starting RTSP handshake.")
        sendRequest("OPTIONS", url: baseURL)

        readLoop(fd: fd)

        // Cleanup.
        stopKeepalive()
        lifecycleLock.lock()
        socketFD = -1
        lifecycleLock.unlock()
        close(fd)

        DispatchQueue.main.async {
            self.isStreaming = false
        }

        let streamed = handshakeComplete
        if streamed {
            debugLog("RTSP session ended.")
        }
        return streamed
    }

    // MARK: - Socket

    private func openSocket(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "\(port)", &hints, &info) == 0, let firstInfo = info else {
            return nil
        }
        defer { freeaddrinfo(firstInfo) }

        let fd = socket(firstInfo.pointee.ai_family, firstInfo.pointee.ai_socktype, firstInfo.pointee.ai_protocol)
        guard fd >= 0 else { return nil }

        // Non-blocking connect with a timeout via poll().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connectResult = connect(fd, firstInfo.pointee.ai_addr, firstInfo.pointee.ai_addrlen)
        if connectResult != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pollFD, 1, Int32(timeout * 1000)) > 0 else {
                close(fd)
                return nil
            }
            var optError: Int32 = 0
            var optLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &optError, &optLen)
            guard optError == 0 else {
                close(fd)
                return nil
            }
        }

        // Restore blocking mode, but give recv a timeout so the read loop can
        // periodically re-check the stop flag.
        _ = fcntl(fd, F_SETFL, flags)
        var recvTimeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        return fd
    }

    private func shutdownSocket() {
        lifecycleLock.lock()
        let fd = socketFD
        lifecycleLock.unlock()
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
        }
    }

    // MARK: - Read loop

    private func readLoop(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)

        while true {
            lifecycleLock.lock()
            let running = isStarted
            lifecycleLock.unlock()
            guard running else { return }

            let received = recv(fd, &buffer, buffer.count, 0)
            if received > 0 {
                autoreleasepool {
                    feed(Data(buffer[0..<received]))
                }
                continue
            }
            if received == 0 {
                debugLog("RTSP connection closed by the server.", level: .error)
                return
            }
            let errorCode = errno
            if errorCode == EAGAIN || errorCode == EWOULDBLOCK || errorCode == EINTR {
                continue // recv timeout — loop re-checks the stop flag.
            }
            debugLog("RTSP recv error (errno \(errorCode)).", level: .error)
            return
        }
    }

    // MARK: - Byte-stream parser

    private func feed(_ data: Data) {
        pendingData.append(data)

        while true {
            if parserMode == .rtspResponse {
                // After PLAY, binary $-frames share the connection; detect and switch.
                if handshakeComplete, let first = pendingData.first, first == 0x24 {
                    parserMode = .interleaved
                    continue
                }

                guard let headerEnd = pendingData.range(of: rtspDelimiter) else { return }
                let headerData = pendingData.subdata(in: 0..<headerEnd.lowerBound)
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    // Not a text response — desync. Drop one byte and resync.
                    pendingData.removeFirst()
                    continue
                }

                var contentLength = 0
                for line in headerText.components(separatedBy: "\r\n") {
                    let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    if kv.count == 2,
                       kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                        contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }

                let bodyStart = headerEnd.upperBound
                let bodyEnd = bodyStart + contentLength
                guard pendingData.count >= bodyEnd else { return }

                let body = contentLength > 0 ? pendingData.subdata(in: bodyStart..<bodyEnd) : Data()
                pendingData.removeSubrange(0..<bodyEnd)
                handleRTSPResponse(header: headerText, body: body)
            } else {
                guard pendingData.count >= 4 else { return }
                let bytes = [UInt8](pendingData.prefix(4))
                if bytes[0] != 0x24 {
                    // Not an interleaved frame — likely a keepalive RTSP response.
                    parserMode = .rtspResponse
                    continue
                }
                let length = (Int(bytes[2]) << 8) | Int(bytes[3])
                guard pendingData.count >= 4 + length else { return }
                let payload = pendingData.subdata(in: 4..<4 + length)
                pendingData.removeSubrange(0..<4 + length)
                if bytes[1] == 0 {
                    handleRTP(payload)
                }
            }
        }
    }

    // MARK: - RTSP handshake

    private func handleRTSPResponse(header: String, body: Data) {
        let lines = header.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return }
        let parts = statusLine.components(separatedBy: " ")
        let statusCode = parts.count > 1 ? Int(parts[1]) ?? 0 : 0

        var responseSession: String?
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = kv[1].trimmingCharacters(in: .whitespaces)
                if key == "session" {
                    responseSession = value
                }
            }
        }

        guard statusCode == 200 else {
            debugLog("RTSP request failed with status \(statusCode) during step \(handshakeStep).", level: .error)
            setMainStatus("RTSP: server a refuzat (\(statusCode))")
            shutdownSocket()
            return
        }

        switch handshakeStep {
        case .options:
            handshakeStep = .describe
            debugLog("OPTIONS ok — sending DESCRIBE.")
            sendRequest("DESCRIBE", url: baseURL, extraHeaders: ["Accept": "application/sdp"])

        case .describe:
            parseSDP(body)
            handshakeStep = .setup
            debugLog("DESCRIBE ok — sending SETUP (RTP/AVP/TCP interleaved).")
            sendRequest("SETUP", url: setupURL, extraHeaders: ["Transport": "RTP/AVP/TCP;interleaved=0-1"])

        case .setup:
            if let responseSession = responseSession {
                sessionID = responseSession.components(separatedBy: ";").first
            }
            handshakeStep = .play
            debugLog("SETUP ok (session \(sessionID ?? "?")) — sending PLAY.")
            sendRequest("PLAY", url: setupURL)

        case .play:
            handshakeStep = .streaming
            handshakeComplete = true
            parserMode = .interleaved
            startKeepalive()
            setMainStatus("RTSP: stream activ")
            debugLog("PLAY ok — streaming. Waiting for H.264 frames...")

        case .streaming:
            break // Keepalive response — nothing to do.
        }
    }

    private func parseSDP(_ body: Data) {
        guard let text = String(data: body, encoding: .utf8) else {
            debugLog("DESCRIBE returned a non-UTF8 SDP body.", level: .error)
            return
        }

        var control: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            }

            if let range = line.range(of: "sprop-parameter-sets=") {
                let value = String(line[range.upperBound...])
                let parts = value.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                if parts.count >= 2,
                   let sps = base64Decode(parts[0]),
                   let pps = base64Decode(parts[1]) {
                    spsData = sps
                    ppsData = pps
                    debugLog("SDP provided SPS (\(sps.count) bytes) and PPS (\(pps.count) bytes).")
                }
            }
        }

        setupURL = resolveControlURL(control)
        debugLog("SDP parsed. SETUP URL: \(setupURL.absoluteString)")
    }

    private func base64Decode(_ string: String) -> Data? {
        var padded = string
        let remainder = padded.count % 4
        if remainder > 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }

    private func resolveControlURL(_ control: String?) -> URL {
        guard let control = control, control != "*", !control.isEmpty else {
            return baseURL
        }
        if control.hasPrefix("rtsp://") {
            return URL(string: control) ?? baseURL
        }
        var baseString = baseURL.absoluteString
        if baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        return URL(string: baseString + "/" + control) ?? baseURL
    }

    // MARK: - Requests

    private func sendRequest(_ method: String, url: URL, extraHeaders: [String: String] = [:]) {
        lifecycleLock.lock()
        let fd = socketFD
        lifecycleLock.unlock()
        guard fd >= 0 else { return }

        var request = "\(method) \(url.absoluteString) RTSP/1.0\r\n"
        request += "CSeq: \(nextCSeq())\r\n"
        request += "User-Agent: SmartGlassesApp/1.0\r\n"
        if let session = sessionID {
            request += "Session: \(session)\r\n"
        }
        for (key, value) in extraHeaders {
            request += "\(key): \(value)\r\n"
        }
        request += "\r\n"

        let data = Data(request.utf8)
        let sent = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return send(fd, base, raw.count, 0)
        }
        if sent != data.count {
            debugLog("Failed to send \(method) (sent \(sent) of \(data.count) bytes).", level: .error)
        } else {
            debugLog("TX \(method) \(url.absoluteString)")
        }
    }

    private func nextCSeq() -> Int {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        cSeq += 1
        return cSeq
    }

    private func startKeepalive() {
        stopKeepalive()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "RTSPClient.keepalive"))
        timer.schedule(deadline: .now() + keepaliveInterval, repeating: keepaliveInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            guard self.handshakeComplete, self.sessionID != nil else { return }
            self.sendRequest("OPTIONS", url: self.baseURL)
        }
        keepaliveTimer = timer
        timer.resume()
    }

    private func stopKeepalive() {
        keepaliveTimer?.cancel()
        keepaliveTimer = nil
    }

    // MARK: - RTP / H.264 depacketization (RFC 6184)

    private func handleRTP(_ packet: Data) {
        guard packet.count >= 12 else { return }
        let bytes = [UInt8](packet)

        let version = bytes[0] >> 6
        guard version == 2 else { return }
        let hasPadding = (bytes[0] >> 5) & 0x01 == 1
        let hasExtension = (bytes[0] >> 4) & 0x01 == 1
        let csrcCount = Int(bytes[0] & 0x0F)
        let marker = (bytes[1] >> 7) & 0x01 == 1

        var offset = 12 + csrcCount * 4
        if hasExtension {
            guard packet.count >= offset + 4 else { return }
            let extensionLength = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            offset += 4 + extensionLength * 4
        }

        var end = packet.count
        if hasPadding, let last = bytes.last {
            end -= Int(last)
        }
        guard offset < end else { return }

        currentRTPTimestamp = (UInt32(bytes[4]) << 24) | (UInt32(bytes[5]) << 16) |
            (UInt32(bytes[6]) << 8) | UInt32(bytes[7])

        let payload = packet.subdata(in: offset..<end)
        depacketizeH264(payload, marker: marker)
    }

    private func depacketizeH264(_ payload: Data, marker: Bool) {
        guard let firstByte = payload.first else { return }
        let nalType = firstByte & 0x1F

        switch nalType {
        case 1...23:
            // Single NAL unit packet.
            handleNAL(payload, endOfAccessUnit: marker)

        case 24:
            // STAP-A: several NAL units, each prefixed with a 2-byte size.
            let bytes = [UInt8](payload)
            var offset = 1
            while offset + 2 <= bytes.count {
                let size = (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
                offset += 2
                guard size > 0, offset + size <= bytes.count else { break }
                handleNAL(Data(bytes[offset..<offset + size]), endOfAccessUnit: false)
                offset += size
            }
            if marker {
                flushAccessUnit()
            }

        case 28:
            // FU-A: fragmented NAL unit.
            guard payload.count >= 2 else { return }
            let bytes = [UInt8](payload)
            let fuIndicator = bytes[0]
            let fuHeader = bytes[1]
            let startBit = (fuHeader >> 7) & 0x01 == 1
            let endBit = (fuHeader >> 6) & 0x01 == 1
            let fragmentType = fuHeader & 0x1F

            let nalHeader = (fuIndicator & 0xE0) | fragmentType
            let fragment = Data([nalHeader]) + payload.subdata(in: 1..<payload.count)

            if startBit {
                fuBuffer = fragment
            } else if let accumulated = fuBuffer {
                fuBuffer = accumulated + fragment
            }

            if endBit, let completeNAL = fuBuffer {
                fuBuffer = nil
                handleNAL(completeNAL, endOfAccessUnit: marker)
            }

        default:
            // MTAP16/MTAP24 (25-27) and FU-B (29) are not used by the glasses.
            break
        }
    }

    private func handleNAL(_ nal: Data, endOfAccessUnit: Bool) {
        guard let firstByte = nal.first else { return }
        let nalType = firstByte & 0x1F

        switch nalType {
        case 7: // SPS
            if nal != spsData {
                spsData = nal
                if decompressionSession != nil {
                    debugLog("SPS changed — recreating the decoder.")
                    teardownDecoder()
                }
            }
        case 8: // PPS
            if nal != ppsData {
                ppsData = nal
                if decompressionSession != nil {
                    debugLog("PPS changed — recreating the decoder.")
                    teardownDecoder()
                }
            }
        case 1...5: // VCL slices — the actual picture data.
            accessUnit.append(nal)
        default:
            break // SEI (6), AUD (9), filler (12) — not needed for decoding.
        }

        if endOfAccessUnit {
            flushAccessUnit()
        }
    }

    private func flushAccessUnit() {
        fuBuffer = nil
        guard !accessUnit.isEmpty else { return }
        let nals = accessUnit
        accessUnit.removeAll()
        decodeAccessUnit(nals, timestamp: currentRTPTimestamp)
    }

    // MARK: - VideoToolbox decoding

    private func obtainDecoder() -> VTDecompressionSession? {
        decoderLock.lock()
        defer { decoderLock.unlock() }

        if let session = decompressionSession {
            return session
        }

        guard let sps = spsData, let pps = ppsData else {
            // SPS/PPS not seen yet — they also arrive in-band before the first IDR frame.
            return nil
        }

        // Immutable copies: withUnsafeBufferPointer yields const
        // UnsafePointer<UInt8> base addresses, which is what
        // CMVideoFormatDescriptionCreateFromH264ParameterSets expects
        // (`const uint8_t * const *`).
        let spsBytes = [UInt8](sps)
        let ppsBytes = [UInt8](pps)
        var format: CMVideoFormatDescription?
        var formatStatus: OSStatus = -1

        spsBytes.withUnsafeBufferPointer { spsBuffer in
            ppsBytes.withUnsafeBufferPointer { ppsBuffer in
                guard let spsPointer = spsBuffer.baseAddress,
                      let ppsPointer = ppsBuffer.baseAddress else { return }
                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsPointer, ppsPointer]
                var parameterSetSizes: [Int] = [spsBuffer.count, ppsBuffer.count]
                formatStatus = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: parameterSetPointers,
                    parameterSetSizes: &parameterSetSizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format
                )
            }
        }

        guard formatStatus == noErr, let format = format else {
            debugLog("Failed to create H.264 format description (status \(formatStatus)).", level: .error)
            return nil
        }

        // No session-level output callback: decoded frames are delivered
        // through the per-frame outputHandler of
        // VTDecompressionSessionDecodeFrame (the WithOutputHandler API path).
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: nil,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard createStatus == noErr, let createdSession = session else {
            debugLog("Failed to create VideoToolbox decoder session (status \(createStatus)).", level: .error)
            return nil
        }

        formatDescription = format
        decompressionSession = createdSession
        debugLog("VideoToolbox H.264 decoder ready.")
        return createdSession
    }

    private func decodeAccessUnit(_ nals: [Data], timestamp: UInt32) {
        guard let session = obtainDecoder() else { return }

        // AVCC-style buffer: [4-byte big-endian length][NAL] per NAL unit.
        var avcc = Data()
        for nal in nals {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        var blockStatus: OSStatus = -1
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let baseAddress = raw.baseAddress else { return }
            blockStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: nil,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                // CMBlockBufferFlags is a plain UInt32 typedef in Swift.
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard blockStatus == kCMBlockBufferNoErr, let createdBuffer = blockBuffer else { return }
            blockStatus = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: createdBuffer,
                offsetIntoDestination: 0,
                dataLength: avcc.count
            )
        }
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer = blockBuffer else {
            debugLog("Failed to build the encoded-frame buffer (status \(blockStatus)).", level: .error)
            return
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestamp), timescale: 90000),
            decodeTimeStamp: CMTime.invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr, let readyBuffer = sampleBuffer else {
            debugLog("Failed to create CMSampleBuffer (status \(sampleStatus)).", level: .error)
            return
        }

        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: readyBuffer,
            flags: [],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer = imageBuffer else { return }
            self?.handleDecodedPixelBuffer(imageBuffer)
        }

        if decodeStatus != noErr {
            debugLog("VTDecompressionSessionDecodeFrame failed (status \(decodeStatus)).", level: .error)
        }
    }

    private func teardownDecoder() {
        decoderLock.lock()
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription = nil
        decoderLock.unlock()
    }

    // MARK: - Decoded frame handling

    private func handleDecodedPixelBuffer(_ imageBuffer: CVImageBuffer) {
        var cgImage: CGImage?
        let status = VTCreateCGImageFromCVPixelBuffer(imageBuffer, options: nil, imageOut: &cgImage)
        guard status == noErr, let cgImage = cgImage else { return }
        let image = UIImage(cgImage: cgImage)

        frameLock.lock()
        _latestFrame = image
        _latestFrameAt = Date()
        frameLock.unlock()

        // Feed directly to StreamRelayServer for full framerate streaming on PC
        StreamRelayServer.shared.updateFrame(image)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.framesDecoded += 1
            let now = Date()
            if now.timeIntervalSince(self.lastPreviewPublish) >= self.previewInterval {
                self.lastPreviewPublish = now
                self.previewFrame = image
            }
        }
    }

    // MARK: - Logging

    private func debugLog(_ message: String, level: DebugLogLevel = .info) {
        print("[DEBUG - RTSP] \(message)")
        DebugLogger.shared.log(message, level: level)
    }

    private func setMainStatus(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
        }
    }
}
