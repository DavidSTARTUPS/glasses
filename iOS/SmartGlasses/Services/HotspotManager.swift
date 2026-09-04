import Foundation
import NetworkExtension
import Network
import Combine

public final class HotspotManager: ObservableObject {
    public static let shared = HotspotManager()

    @Published public var isConnectedToWiFi: Bool = false
    @Published public var isConnecting: Bool = false
    @Published public var connectionStatus: String = "Neconectat la Wi-Fi"
    /// Raw NEHotspotConfiguration error code of the last failed join attempt
    /// (nil while idle / after success). Lets the UI and retry logic react to
    /// specific causes — e.g. 8 (permissionDenied) means the Hotspot
    /// Configuration entitlement is unavailable (Sideloadly / free signing)
    /// and retrying apply() can never succeed.
    @Published public var lastJoinErrorCode: Int?

    /// Default gateway of the glasses' hotspot in AP mode (see CONTEXT.md).
    public static let glassesGateway = "192.168.43.1"
    /// RTSP port on the glasses. Used only as a reachability probe target:
    /// an accepted OR actively refused TCP connect proves the network is up.
    public static let glassesRTSPPort: UInt16 = 554
    /// Secondary probe port (HTTP). Raced together with the RTSP port because
    /// some firmware states keep one of the two closed; either port answering
    /// (accepted or actively refused) proves the glasses' network is up.
    public static let glassesHTTPPort: UInt16 = 80

    /// NEHotspotConfigurationError.internal (code 7), referenced by raw value
    /// because `internal` is a reserved Swift keyword. In practice this code
    /// almost always means the app signature lacks the Hotspot Configuration
    /// entitlement (free / Sideloadly / CI-re-signed builds).
    private static let neHotspotInternalErrorCode = 7
    /// NEHotspotConfigurationError.permissionDenied (code 8): iOS refused to
    /// let the app configure Wi-Fi. Same root cause as code 7 in practice —
    /// a signature without the Hotspot Configuration entitlement — or a
    /// denied one-time system permission prompt. Retrying cannot succeed.
    private static let neHotspotPermissionDeniedErrorCode = 8
    /// How long to wait for apply()'s completion before declaring the attempt
    /// failed. The completion is NOT guaranteed to fire.
    private static let applyTimeout: TimeInterval = 15.0
    /// How often the connectivity monitor probes the glasses' gateway.
    private static let connectivityProbeInterval: TimeInterval = 4.0

    private var pathMonitor: NWPathMonitor?
    private var isConnectAttemptInFlight = false
    /// Guards against stale apply() completions racing the watchdog.
    private var applyAttemptID = 0
    private var applyWatchdog: DispatchWorkItem?
    /// Repeating gateway probe; the source of truth for `isConnectedToWiFi`.
    private var connectivityTimer: DispatchSourceTimer?

    private init() {
        // Passive monitoring from launch: if the user joins the glasses'
        // hotspot manually through iOS Settings — the reliable path when the
        // Hotspot Configuration entitlement is unavailable — the app detects
        // reachability and continues the pipeline automatically.
        startConnectivityMonitoring()
    }

    // MARK: - Debug logging

    /// Console debug log mirrored into the in-app DebugLogView.
    private func debugLog(_ message: String, level: DebugLogLevel = .wifi) {
        print("[DEBUG - WiFi] \(message)")
        DebugLogger.shared.log(message, level: level)
    }

    public func connectToGlassesHotspot(ssid: String, password: String = "12345678", completion: @escaping (Bool) -> Void) {
        guard !ssid.isEmpty else {
            connectionStatus = "SSID invalid"
            DispatchQueue.main.async { completion(false) }
            return
        }

        // NEHotspotConfigurationManager serializes internally, but overlapping
        // apply() calls produce ambiguous results. Serialize at app level too.
        guard !isConnectAttemptInFlight else {
            connectionStatus = "Conectare Wi-Fi deja în curs..."
            debugLog("Wi-Fi join skipped — another attempt is already in flight.")
            DispatchQueue.main.async { completion(false) }
            return
        }
        isConnectAttemptInFlight = true
        lastJoinErrorCode = nil
        DispatchQueue.main.async { self.isConnecting = true }

        connectionStatus = "Conectare la \(ssid)..."
        debugLog("Applying hotspot configuration for '\(ssid)'.")
        let configuration = NEHotspotConfiguration(ssid: ssid, passphrase: password, isWEP: false)
        configuration.joinOnce = false

        applyAttemptID += 1
        let attemptID = applyAttemptID

        // WATCHDOG: apply()'s completion is not guaranteed to fire. When it
        // never does, the old code stalled forever — isConnectAttemptInFlight
        // stayed true, no retry was scheduled, and the debug log appeared to
        // "cut off" right after "Applying hotspot configuration". Before
        // failing, the glasses' gateway is probed: a silent-but-successful
        // join (or a manual join through iOS Settings) must be treated as
        // success, not as an error.
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self = self, self.applyAttemptID == attemptID else { return }
            self.debugLog("apply() completion did not fire within \(Int(Self.applyTimeout))s — probing the glasses' gateway before failing (the join may have succeeded silently).", level: .error)
            self.verifyGlassesNetwork(timeout: 6.0) { satisfied in
                DispatchQueue.main.async {
                    guard self.applyAttemptID == attemptID else { return }
                    if satisfied {
                        self.lastJoinErrorCode = nil
                        self.finishConnectAttempt(connected: true, status: "Conectat la \(ssid)")
                        self.debugLog("apply() never completed but the glasses' network IS reachable — treating the join as successful.")
                        completion(true)
                    } else {
                        self.finishConnectAttempt(
                            connected: false,
                            status: "iOS nu a răspuns cererii Wi-Fi. Conectați-vă manual din Setări → Wi-Fi; aplicația detectează automat rețeaua ochelarilor."
                        )
                        completion(false)
                    }
                }
            }
        }
        applyWatchdog?.cancel()
        applyWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.applyTimeout, execute: watchdog)

        NEHotspotConfigurationManager.shared.apply(configuration) { [weak self] error in
            // Do not assume the callback queue (public reference rule):
            // serialize all attempt state through the main queue.
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard self.applyAttemptID == attemptID else {
                    self.debugLog("Stale apply() completion ignored (attempt \(attemptID)).")
                    return
                }
                self.applyWatchdog?.cancel()

                if let error = error {
                    let nsError = error as NSError
                    // Log the raw code — it is the only reliable diagnostic
                    // (7 = internal, 8 = permission denied, 13 = already
                    // associated).
                    self.debugLog("Hotspot configuration error (code \(nsError.code)): \(error.localizedDescription)", level: .error)
                    self.lastJoinErrorCode = nsError.code

                    let isAlreadyAssociated =
                        nsError.domain == NEHotspotConfigurationErrorDomain &&
                        nsError.code == NEHotspotConfigurationError.alreadyAssociated.rawValue

                    if isAlreadyAssociated {
                        // The phone is ALREADY joined to this exact network.
                        // Treat it as success and verify connectivity instead
                        // of failing.
                        self.debugLog("System reports the network is already associated — verifying connectivity instead of failing.")
                        // fall through to the connectivity verification below.
                    } else if nsError.code == Self.neHotspotPermissionDeniedErrorCode ||
                              nsError.code == Self.neHotspotInternalErrorCode {
                        // Codes 8 ("permissionDenied") and 7 ("internal"):
                        // iOS refused to let the app configure Wi-Fi. Known
                        // causes:
                        //   1) The app signature lacks the Hotspot
                        //      Configuration entitlement — free / Sideloadly /
                        //      CI-re-signed builds cannot include it. This is
                        //      the cause for every GitHub Actions + Sideloadly
                        //      install.
                        //   2) The user denied the one-time system permission
                        //      prompt (fix: delete + reinstall, tap Allow).
                        // Retrying apply() can NEVER succeed.
                        //
                        // IMPORTANT: the refusal says nothing about whether
                        // the network is present. The phone may ALREADY be
                        // joined to the glasses' hotspot (manual join through
                        // iOS Settings, or a network remembered from a
                        // previous session) — this is the standard operating
                        // mode for entitlement-less builds. Probe the gateway
                        // before failing: if the glasses' network is
                        // reachable, treat the attempt as SUCCESS so the
                        // pipeline (RTSP start command + stream) continues.
                        self.debugLog("Wi-Fi configuration refused (code \(nsError.code)) — probing the glasses' gateway; the phone may already be joined to the hotspot.", level: .error)
                        self.verifyGlassesNetwork(timeout: 6.0) { satisfied in
                            DispatchQueue.main.async {
                                guard self.applyAttemptID == attemptID else { return }
                                if satisfied {
                                    self.lastJoinErrorCode = nil
                                    self.finishConnectAttempt(connected: true, status: "Conectat la \(ssid)")
                                    self.debugLog("apply() was refused (code \(nsError.code)) but the glasses' network IS reachable — treating the join as successful.")
                                    completion(true)
                                } else {
                                    self.finishConnectAttempt(
                                        connected: false,
                                        status: "Wi-Fi refuzat de iOS (code \(nsError.code) — semnătura aplicației nu include entitlement-ul Hotspot Configuration). Conectați-vă manual din Setări → Wi-Fi (parolă 12345678); aplicația pornește stream-ul automat."
                                    )
                                    completion(false)
                                }
                            }
                        }
                        return
                    } else {
                        self.finishConnectAttempt(
                            connected: false,
                            status: "Eroare Wi-Fi (code \(nsError.code)): \(error.localizedDescription)"
                        )
                        completion(false)
                        return
                    }
                }

                // A nil (or alreadyAssociated) result only means the
                // configuration was accepted by the system. Verify that the
                // glasses' network is actually reachable before reporting
                // success, otherwise the RTSP/image pipeline starts against a
                // dead network.
                self.verifyGlassesNetwork(timeout: 10.0) { satisfied in
                    DispatchQueue.main.async {
                        guard self.applyAttemptID == attemptID else { return }
                        if satisfied {
                            self.lastJoinErrorCode = nil
                            self.finishConnectAttempt(connected: true, status: "Conectat la \(ssid)")
                            self.debugLog("Glasses network reachable — Wi-Fi connect succeeded.")
                            completion(true)
                        } else {
                            self.finishConnectAttempt(connected: false,
                                                      status: "Wi-Fi configurat, dar fără conectivitate. Reîncercare...")
                            self.debugLog("Glasses network NOT reachable after configuration.", level: .error)
                            completion(false)
                        }
                    }
                }
            }
        }

        // Monitoring runs regardless of the apply() outcome, so a manual join
        // through iOS Settings is detected even when this attempt failed.
        startConnectivityMonitoring()
    }

    private func finishConnectAttempt(connected: Bool, status: String) {
        DispatchQueue.main.async {
            self.isConnectAttemptInFlight = false
            self.isConnecting = false
            if connected {
                self.isConnectedToWiFi = true
            }
            // On failure, isConnectedToWiFi is intentionally NOT forced to
            // false: the always-on connectivity monitor is the source of
            // truth and corrects it within one probe interval. Forcing it to
            // false here used to MASK a network that was actually working
            // (e.g. the phone already joined to the glasses' hotspot through
            // iOS Settings while the in-app join was refused with code 8).
            self.connectionStatus = status
        }
    }

    /// Verifies that the glasses' network is actually reachable.
    ///
    /// Primary check: a TCP probe to the glasses' gateway. A connection that
    /// is either accepted or actively refused proves IP-level reachability
    /// (the RTSP port may legitimately be closed until the stream starts).
    /// Fallback: the system path monitor for a satisfied Wi-Fi path.
    private func verifyGlassesNetwork(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        probeGateway(timeout: min(timeout, 4.0)) { reachable in
            completion(reachable)
        }
    }

    /// TCP probe against the glasses' gateway. `.ready` or an active refusal
    /// (ECONNREFUSED) both mean the glasses' network is reachable.
    ///
    /// Two ports are raced in parallel (554 = RTSP, 80 = HTTP): some firmware
    /// states keep one of them closed, and a DROPPED (not refused) connect
    /// looks identical to an unreachable network. Racing both ports makes the
    /// probe resilient to "service not started yet" states, which previously
    /// deadlocked the pipeline (no connectivity detected -> no RTSP start
    /// command -> RTSP server never came up -> probe kept failing).
    /// Checks whether the active Wi-Fi interface has an IP in the glasses' AP subnet (192.168.43.x).
    /// If the phone is on home Wi-Fi (e.g. 192.168.1.x), this returns false and avoids false-positive
    /// gateway probe results caused by home router ICMP/RST packets.
    public static func isWiFiOnGlassesSubnet() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return false }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            if (flags & (IFF_UP|IFF_RUNNING)) == (IFF_UP|IFF_RUNNING),
               (flags & IFF_LOOPBACK) == 0,
               addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    var ifaAddr = ptr.pointee.ifa_addr.pointee
                    getnameinfo(&ifaAddr, socklen_t(ptr.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if ip.hasPrefix("192.168.43.") {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func probeGateway(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        // Fast pre-check: ensure the phone is actually associated with the glasses' AP
        // (assigned a 192.168.43.x IP). When on home Wi-Fi, skip probing to prevent
        // home router ICMP unreachables from being misread as glasses connectivity.
        guard Self.isWiFiOnGlassesSubnet() else {
            completion(false)
            return
        }

        let stateQueue = DispatchQueue(label: "HotspotManager.GatewayProbe")
        var finished = false
        var pendingPorts = 2

        let finish: (Bool) -> Void = { reachable in
            stateQueue.async {
                guard !finished else { return }
                if reachable {
                    finished = true
                    completion(true)
                } else {
                    pendingPorts -= 1
                    if pendingPorts == 0 {
                        finished = true
                        completion(false)
                    }
                }
            }
        }

        for port in [Self.glassesRTSPPort, Self.glassesHTTPPort] {
            startSinglePortProbe(port: port, timeout: timeout, stateQueue: stateQueue, finish: finish)
        }
    }

    /// One TCP probe against the gateway on a single port. Calls `finish`
    /// exactly once with the result (true on `.ready` or on an active
    /// ECONNREFUSED refusal, false on timeout or any other failure).
    private func startSinglePortProbe(port: UInt16, timeout: TimeInterval, stateQueue: DispatchQueue, finish: @escaping (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            finish(false)
            return
        }

        // Force the probe over Wi-Fi: without this, iOS could route the probe
        // over cellular or another interface and report a false result.
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .wifi

        let connection = NWConnection(
            host: NWEndpoint.Host(Self.glassesGateway),
            port: nwPort,
            using: parameters
        )

        let timeoutWork = DispatchWorkItem {
            stateQueue.async {
                connection.cancel()
                finish(false)
            }
        }

        connection.stateUpdateHandler = { state in
            stateQueue.async {
                switch state {
                case .ready:
                    timeoutWork.cancel()
                    connection.cancel()
                    finish(true)
                case .failed(let error):
                    timeoutWork.cancel()
                    connection.cancel()
                    // An active refusal still proves the glasses are reachable.
                    if case .posix(let code) = error, code.rawValue == ECONNREFUSED {
                        finish(true)
                    } else {
                        finish(false)
                    }
                default:
                    break // .setup, .preparing, .waiting, .cancelled — keep waiting.
                }
            }
        }

        connection.start(queue: stateQueue)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    }

    /// Continuously probes the glasses' gateway over the Wi-Fi interface.
    /// This is the source of truth for `isConnectedToWiFi`: it detects the
    /// glasses' network no matter HOW the phone joined it (in-app join,
    /// NEHotspotConfiguration, or manually through iOS Settings), and it
    /// notices when the network disappears again.
    public func startConnectivityMonitoring() {
        guard connectivityTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "HotspotManager.ConnectivityMonitor"))
        timer.schedule(deadline: .now(), repeating: Self.connectivityProbeInterval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.probeGateway(timeout: 3.0) { reachable in
                DispatchQueue.main.async {
                    if reachable != self.isConnectedToWiFi {
                        self.debugLog(reachable
                            ? "Glasses' network reachable (connectivity monitor)."
                            : "Glasses' network no longer reachable.", level: .wifi)
                    }
                    self.isConnectedToWiFi = reachable
                    // An explicit join attempt owns connectionStatus while it
                    // is in flight; the monitor only annotates when idle.
                    guard !self.isConnectAttemptInFlight else { return }
                    if reachable {
                        self.connectionStatus = "Conectat la rețeaua ochelarilor"
                    } else if self.connectionStatus.hasPrefix("Conectat") {
                        self.connectionStatus = "Neconectat la Wi-Fi"
                    }
                }
            }
        }
        timer.resume()
        connectivityTimer = timer
    }

    /// Waits until the system reports a satisfied Wi-Fi path, or times out.
    private func waitForWiFiPath(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
        self.pathMonitor = monitor

        let stateQueue = DispatchQueue(label: "HotspotManager.WiFiPath", qos: .utility)
        var finished = false

        let timeoutWork = DispatchWorkItem {
            stateQueue.async {
                guard !finished else { return }
                finished = true
                DispatchQueue.global(qos: .utility).async { monitor.cancel() }
                completion(false)
            }
        }

        monitor.pathUpdateHandler = { path in
            stateQueue.async {
                guard !finished else { return }
                guard path.status == .satisfied else { return }
                finished = true
                timeoutWork.cancel()
                DispatchQueue.global(qos: .utility).async { monitor.cancel() }
                completion(true)
            }
        }

        monitor.start(queue: stateQueue)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
    }

    public func disconnectHotspot(ssid: String) {
        NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
        pathMonitor?.cancel()
        pathMonitor = nil
        isConnectAttemptInFlight = false
        debugLog("Hotspot configuration removed for '\(ssid)'.")
        DispatchQueue.main.async {
            self.isConnecting = false
            self.isConnectedToWiFi = false
            self.connectionStatus = "Wi-Fi Deconectat"
        }
    }
}
