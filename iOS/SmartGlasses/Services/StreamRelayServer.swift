import Foundation
import UIKit
import Network
import Combine

/// A high-performance, zero-dependency HTTP MJPEG stream relay server running directly
/// inside the iOS app.
///
/// It acts as a bridge / antenna:
/// 1. Listens on port 8080 on all interfaces (Local Wi-Fi + Tailscale VPN).
/// 2. Serves a rich HTML5 live video console on `GET /` playable in any browser (Chrome, Edge).
/// 3. Streams raw MJPEG on `GET /live` and `GET /stream` for VLC Player, OBS Studio, or ffmpeg.
/// 4. Serves single JPEG snapshots on `GET /snapshot`.
/// 5. Automatically feeds from RTSPClient or GlassesPhotoStore, with an animated high-tech
///    diagnostic HUD fallback so VLC and Chrome never hang or time out while buffering.
public final class StreamRelayServer: ObservableObject {
    public static let shared = StreamRelayServer()

    public static let defaultPort: UInt16 = 8080

    // MARK: - Published state (for UI)
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var activeClientsCount: Int = 0
    @Published public private(set) var localURLs: [String] = []
    @Published public private(set) var tailscaleURLs: [String] = []
    @Published public private(set) var primaryURL: String = ""
    @Published public private(set) var primaryWebURL: String = ""

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.smartglasses.streamrelay", qos: .userInteractive)

    private final class ClientContext {
        let connection: NWConnection
        var isSending: Bool = false
        init(connection: NWConnection) {
            self.connection = connection
        }
    }

    private var mjpegClients: [UUID: ClientContext] = [:]
    private let clientsLock = NSLock()

    private var broadcastTimer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()

    private var latestFrameJPEG: Data?
    private var lastFrameTime: Date = .distantPast

    // HUD caching to save CPU
    private var cachedHUDData: Data?
    private var cachedHUDSecond: Int = -1

    private init() {
        startServer()
        setupFrameSubscriptions()
    }

    // MARK: - Lifecycle

    public func startServer(port: UInt16 = defaultPort) {
        stopServer()

        do {
            let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port(rawValue: Self.defaultPort)!
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: nwPort)
            listener?.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.refreshNetworkAddresses(port: port)
                        DebugLogger.shared.log("Stream Relay HTTP server pornit pe portul \(port).", level: .info)
                    case .failed(let error):
                        self?.isRunning = false
                        DebugLogger.shared.log("Stream Relay server failed: \(error.localizedDescription)", level: .error)
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingConnection(connection)
            }

            listener?.start(queue: queue)
            startBroadcastLoop()
        } catch {
            DebugLogger.shared.log("Nu s-a putut porni Stream Relay server: \(error.localizedDescription)", level: .error)
        }
    }

    public func stopServer() {
        broadcastTimer?.cancel()
        broadcastTimer = nil

        clientsLock.lock()
        for (_, client) in mjpegClients {
            client.connection.cancel()
        }
        mjpegClients.removeAll()
        clientsLock.unlock()

        listener?.cancel()
        listener = nil

        DispatchQueue.main.async {
            self.isRunning = false
            self.activeClientsCount = 0
        }
    }

    // MARK: - Frame updates

    private func setupFrameSubscriptions() {
        // Subscribe to RTSP preview frame as fallback
        RTSPClient.shared.$previewFrame
            .compactMap { $0 }
            .sink { [weak self] frame in
                self?.updateFrame(frame)
            }
            .store(in: &cancellables)

        // Subscribe to latest BLE photo
        GlassesPhotoStore.shared.$latestPhoto
            .compactMap { $0 }
            .sink { [weak self] frame in
                self?.updateFrame(frame)
            }
            .store(in: &cancellables)
    }

    public func updateFrame(_ image: UIImage) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let jpeg = image.jpegData(compressionQuality: 0.72) {
                self.latestFrameJPEG = jpeg
                self.lastFrameTime = Date()
            }
        }
    }

    // MARK: - Connection & HTTP Handling

    private func handleIncomingConnection(_ connection: NWConnection) {
        connection.start(queue: queue)

        // Read HTTP request header
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self = self, error == nil, let data = data, let req = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            let firstLine = req.components(separatedBy: "\r\n").first ?? ""
            let parts = firstLine.components(separatedBy: " ")
            guard parts.count >= 2 else {
                connection.cancel()
                return
            }

            let method = parts[0]
            let path = parts[1]

            if method == "GET" {
                if path == "/live" || path == "/stream" {
                    self.registerMJPEGClient(connection)
                } else if path == "/snapshot" {
                    self.sendSingleSnapshot(to: connection)
                } else if path == "/status" {
                    self.sendStatusJSON(to: connection)
                } else if path == "/" || path == "/index.html" {
                    self.sendHTMLConsole(to: connection)
                } else {
                    // Default route: if a browser or VLC accesses an unknown path, send MJPEG
                    self.registerMJPEGClient(connection)
                }
            } else {
                connection.cancel()
            }
        }
    }

    private func registerMJPEGClient(_ connection: NWConnection) {
        let clientId = UUID()
        let context = ClientContext(connection: connection)

        clientsLock.lock()
        mjpegClients[clientId] = context
        let count = mjpegClients.count
        clientsLock.unlock()

        DispatchQueue.main.async {
            self.activeClientsCount = count
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.removeClient(clientId)
            default:
                break
            }
        }

        // Send standard MJPEG multipart header
        let header = "HTTP/1.1 200 OK\r\n" +
            "Server: SmartGlassesRelay/1.0\r\n" +
            "Connection: close\r\n" +
            "Cache-Control: no-cache, private, max-age=0, must-revalidate\r\n" +
            "Pragma: no-cache\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Content-Type: multipart/x-mixed-replace; boundary=--smartglasses_boundary\r\n\r\n"

        if let data = header.data(using: .utf8) {
            connection.send(content: data, completion: .contentProcessed({ [weak self] error in
                if error != nil {
                    self?.removeClient(clientId)
                }
            }))
        }
    }

    private func removeClient(_ id: UUID) {
        clientsLock.lock()
        mjpegClients.removeValue(forKey: id)
        let count = mjpegClients.count
        clientsLock.unlock()

        DispatchQueue.main.async {
            self.activeClientsCount = count
        }
    }

    private func sendSingleSnapshot(to connection: NWConnection) {
        let frameData = latestFrameJPEG ?? getCurrentHUDFrame()
        let header = "HTTP/1.1 200 OK\r\n" +
            "Server: SmartGlassesRelay/1.0\r\n" +
            "Content-Type: image/jpeg\r\n" +
            "Content-Length: \(frameData.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(frameData)
        connection.send(content: response, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendStatusJSON(to connection: NWConnection) {
        let isBLEOk = BLEManager.shared.isDeviceConnected
        let isWiFiOk = HotspotManager.shared.isConnectedToWiFi
        let isRTSPOk = RTSPClient.shared.isStreaming

        let json = "{\"running\":true,\"ble\":\(isBLEOk),\"wifi\":\(isWiFiOk),\"rtsp\":\(isRTSPOk),\"clients\":\(activeClientsCount)}"
        let header = "HTTP/1.1 200 OK\r\n" +
            "Server: SmartGlassesRelay/1.0\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(json.utf8.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(Data(json.utf8))
        connection.send(content: response, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    private func sendHTMLConsole(to connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html lang="ro">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>SmartGlasses Live Relay Console</title>
          <style>
            * { box-sizing: border-box; margin: 0; padding: 0; }
            body {
              background: #090d16;
              color: #f1f5f9;
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              display: flex;
              flex-direction: column;
              align-items: center;
              min-height: 100vh;
            }
            header {
              width: 100%;
              padding: 16px 28px;
              background: rgba(15, 23, 42, 0.9);
              border-bottom: 1px solid rgba(255, 255, 255, 0.08);
              display: flex;
              justify-content: space-between;
              align-items: center;
            }
            .brand {
              display: flex;
              align-items: center;
              gap: 10px;
              font-size: 19px;
              font-weight: 700;
              letter-spacing: -0.02em;
              color: #38bdf8;
            }
            .badge-live {
              background: rgba(16, 185, 129, 0.18);
              color: #34d399;
              border: 1px solid rgba(52, 211, 153, 0.35);
              padding: 5px 14px;
              border-radius: 9999px;
              font-size: 12px;
              font-weight: 700;
              letter-spacing: 0.05em;
            }
            .main-content {
              width: 95%;
              max-width: 1060px;
              margin: 24px auto;
              display: flex;
              flex-direction: column;
              align-items: center;
              gap: 20px;
            }
            .stream-box {
              width: 100%;
              background: #000;
              border-radius: 18px;
              overflow: hidden;
              box-shadow: 0 16px 40px rgba(0, 0, 0, 0.7), 0 0 25px rgba(56, 189, 248, 0.12);
              border: 1px solid rgba(255, 255, 255, 0.1);
              display: flex;
              justify-content: center;
              align-items: center;
              position: relative;
            }
            .stream-feed {
              width: 100%;
              height: auto;
              max-height: 72vh;
              object-fit: contain;
              display: block;
            }
            .grid-cards {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(260px, 1fr));
              gap: 16px;
              width: 100%;
            }
            .card {
              background: rgba(30, 41, 59, 0.6);
              border: 1px solid rgba(255, 255, 255, 0.08);
              border-radius: 14px;
              padding: 16px 20px;
            }
            .card-title {
              font-size: 11px;
              text-transform: uppercase;
              letter-spacing: 0.06em;
              color: #94a3b8;
              margin-bottom: 8px;
            }
            .card-val {
              font-size: 14px;
              font-family: monospace;
              color: #38bdf8;
              word-break: break-all;
            }
            .btn {
              display: inline-block;
              background: #0284c7;
              color: white;
              text-decoration: none;
              padding: 9px 18px;
              border-radius: 8px;
              font-size: 13px;
              font-weight: 600;
              margin-top: 8px;
              transition: 0.2s;
            }
            .btn:hover { background: #0369a1; }
          </style>
        </head>
        <body>
          <header>
            <div class="brand">👓 MT5 SMARTGLASSES RELAY</div>
            <div class="badge-live">● CONEXIUNE ACTIVĂ PC</div>
          </header>
          <div class="main-content">
            <div class="stream-box">
              <img class="stream-feed" src="/live" alt="Flux Live Camera Ochelari" />
            </div>
            <div class="grid-cards">
              <div class="card">
                <div class="card-title">Flux Direct VLC / OBS Studio</div>
                <div class="card-val" id="vlcLink">http://.../live</div>
                <p style="font-size: 12px; color: #94a3b8; margin-top: 6px;">
                  În VLC: Media → Open Network Stream → introdu linkul de mai sus.
                </p>
              </div>
              <div class="card">
                <div class="card-title">Captură Foto Instantă</div>
                <div class="card-val">Imagine statică JPEG</div>
                <a class="btn" href="/snapshot" target="_blank">Deschide Snapshot</a>
              </div>
            </div>
          </div>
          <script>
            document.getElementById('vlcLink').innerText = window.location.origin + '/live';
          </script>
        </body>
        </html>
        """

        let header = "HTTP/1.1 200 OK\r\n" +
            "Server: SmartGlassesRelay/1.0\r\n" +
            "Content-Type: text/html; charset=utf-8\r\n" +
            "Content-Length: \(html.utf8.count)\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(Data(html.utf8))
        connection.send(content: response, isComplete: true, completion: .contentProcessed({ _ in
            connection.cancel()
        }))
    }

    // MARK: - Broadcast Loop (MJPEG streaming)

    private func startBroadcastLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Broadcast at ~18 FPS (55ms interval)
        timer.schedule(deadline: .now(), repeating: .milliseconds(55))
        timer.setEventHandler { [weak self] in
            self?.broadcastNextFrame()
        }
        timer.resume()
        broadcastTimer = timer
    }

    private func broadcastNextFrame() {
        clientsLock.lock()
        let clients = Array(mjpegClients.values)
        clientsLock.unlock()

        guard !clients.isEmpty else { return }

        // Determine frame data: live camera frame if fresh (< 3.0s), otherwise fallback HUD
        let frameData: Data
        if let live = latestFrameJPEG, Date().timeIntervalSince(lastFrameTime) < 3.0 {
            frameData = live
        } else {
            frameData = getCurrentHUDFrame()
        }

        let boundary = "--smartglasses_boundary\r\n" +
            "Content-Type: image/jpeg\r\n" +
            "Content-Length: \(frameData.count)\r\n\r\n"

        var packet = Data(boundary.utf8)
        packet.append(frameData)
        packet.append(Data("\r\n".utf8))

        for client in clients {
            // Drop frame for this client if previous send is still in flight (prevents latency buildup)
            if client.isSending { continue }

            client.isSending = true
            client.connection.send(content: packet, completion: .contentProcessed({ error in
                client.isSending = false
                if error != nil {
                    client.connection.cancel()
                }
            }))
        }
    }

    // MARK: - Diagnostic Fallback HUD Frame (Optimized with caching)

    private func getCurrentHUDFrame() -> Data {
        let calendar = Calendar.current
        let currentSecond = calendar.component(.second, from: Date())
        if currentSecond == cachedHUDSecond, let cached = cachedHUDData {
            return cached
        }

        let statusText = BLEManager.shared.isDeviceConnected ? "Ochelari conectați (BLE activ)" : "Căutare ochelari BLE..."
        let data = generateHUDFrame(text: statusText)
        cachedHUDData = data
        cachedHUDSecond = currentSecond
        return data
    }

    private func generateHUDFrame(text: String) -> Data {
        let size = CGSize(width: 640, height: 360)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let image = renderer.image { ctx in
            // Dark futuristic background
            UIColor(red: 0.05, green: 0.07, blue: 0.12, alpha: 1.0).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))

            // Border
            UIColor(red: 0.12, green: 0.74, blue: 0.97, alpha: 0.5).setStroke()
            let border = UIBezierPath(roundedRect: CGRect(x: 14, y: 14, width: 612, height: 332), cornerRadius: 12)
            border.lineWidth = 2
            border.stroke()

            // Header title
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 20, weight: .bold),
                .foregroundColor: UIColor(red: 0.12, green: 0.74, blue: 0.97, alpha: 1.0)
            ]
            "📡 SMARTGLASSES LIVE STREAM RELAY".draw(at: CGPoint(x: 35, y: 35), withAttributes: titleAttrs)

            // Status message
            let statusAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            "Stare: \(text)".draw(at: CGPoint(x: 35, y: 80), withAttributes: statusAttrs)

            let tipAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: UIColor(red: 0.7, green: 0.85, blue: 1.0, alpha: 1.0)
            ]
            "Conexiune activă iPhone <-> PC prin Tailscale / Wi-Fi local!".draw(at: CGPoint(x: 35, y: 125), withAttributes: tipAttrs)
            "Deschide pe calculator în Google Chrome sau VLC Player.".draw(at: CGPoint(x: 35, y: 150), withAttributes: tipAttrs)

            // URL hints
            let urlAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: UIColor(red: 0.2, green: 0.9, blue: 0.5, alpha: 1.0)
            ]
            let displayURL = primaryURL.isEmpty ? "Se detectează adresele..." : primaryURL
            "Link PC: \(displayURL)".draw(at: CGPoint(x: 35, y: 195), withAttributes: urlAttrs)

            // Timestamp
            let timeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: 12, weight: .light),
                .foregroundColor: UIColor.gray
            ]
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            "Ora iPhone: \(formatter.string(from: Date())) | MJPEG 20 FPS".draw(at: CGPoint(x: 35, y: 305), withAttributes: timeAttrs)
        }

        return image.jpegData(compressionQuality: 0.65) ?? Data()
    }

    // MARK: - Network IP Discovery

    public func refreshNetworkAddresses(port: UInt16 = defaultPort) {
        var local: [String] = []
        var tailscale: [String] = []

        for addr in getLocalIPAddresses() {
            let streamURL = "http://\(addr.ip):\(port)/live"
            if addr.isTailscale {
                tailscale.append(streamURL)
            } else {
                local.append(streamURL)
            }
        }

        DispatchQueue.main.async {
            self.localURLs = local
            self.tailscaleURLs = tailscale
            let stream = tailscale.first ?? local.first ?? "http://127.0.0.1:\(port)/live"
            self.primaryURL = stream
            self.primaryWebURL = stream.replacingOccurrences(of: "/live", with: "")
        }
    }

    private func getLocalIPAddresses() -> [(name: String, ip: String, isTailscale: Bool)] {
        var addresses: [(name: String, ip: String, isTailscale: Bool)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               addr.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                var ifaAddr = ptr.pointee.ifa_addr.pointee
                getnameinfo(&ifaAddr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                            &hostname, socklen_t(hostname.count),
                            nil, 0, NI_NUMERICHOST)
                let ip = String(cString: hostname)
                let name = String(cString: ptr.pointee.ifa_name)

                // Filter out glasses internal hotspot subnet (192.168.43.x) because PC cannot route to it
                if !ip.hasPrefix("192.168.43.") {
                    let isTailscale = name.hasPrefix("utun") || ip.hasPrefix("100.")
                    addresses.append((name: name, ip: ip, isTailscale: isTailscale))
                }
            }
        }
        return addresses
    }
}
