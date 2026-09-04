import Foundation
import UIKit
import CoreBluetooth
import Combine
import AIBuds
import ABMate
import AIBudsFoundation

/// A peripheral seen during scanning. Listed in the manual device picker for
/// when the automatic candidate validation cannot recognize the glasses.
public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String
    public let rssi: Int

    public init(id: UUID, name: String, rssi: Int) {
        self.id = id
        self.name = name
        self.rssi = rssi
    }
}

// MARK: - Delegate Multiplexer
// CoreBluetooth allows only ONE delegate per peripheral. With the official
// SDK end-to-end flow the AIBuds SDK installs itself as the peripheral's
// delegate when it connects, which would silently cut BLEManager off from
// the notification stream — killing the raw ABMate parsing (0x10 hotspot
// events, 0x12 mode ack, 0x02 battery, 0x55 media) while the SDK uses the
// same stream for its handshake and photo reassembly. The link liveness
// monitor detects the takeover and installs this multiplexer so BOTH
// consumers receive the callbacks. Consumers are held weakly: when the SDK
// device is released, the multiplexer degrades gracefully to forwarding to
// BLEManager only.

/// Forwards CBPeripheralDelegate callbacks to two consumers.
final class PeripheralDelegateMultiplexer: NSObject, CBPeripheralDelegate {
    weak var first: CBPeripheralDelegate?
    weak var second: CBPeripheralDelegate?

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        first?.peripheral?(peripheral, didDiscoverServices: error)
        second?.peripheral?(peripheral, didDiscoverServices: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        first?.peripheral?(peripheral, didDiscoverCharacteristicsFor: service, error: error)
        second?.peripheral?(peripheral, didDiscoverCharacteristicsFor: service, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        first?.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
        second?.peripheral?(peripheral, didUpdateValueFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        first?.peripheral?(peripheral, didUpdateValueFor: descriptor, error: error)
        second?.peripheral?(peripheral, didUpdateValueFor: descriptor, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        first?.peripheral?(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
        second?.peripheral?(peripheral, didUpdateNotificationStateFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        first?.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
        second?.peripheral?(peripheral, didWriteValueFor: characteristic, error: error)
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        first?.peripheral?(peripheral, didReadRSSI: RSSI, error: error)
        second?.peripheral?(peripheral, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        first?.peripheralDidUpdateName?(peripheral)
        second?.peripheralDidUpdateName?(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        first?.peripheral?(peripheral, didModifyServices: invalidatedServices)
        second?.peripheral?(peripheral, didModifyServices: invalidatedServices)
    }
}

public final class BLEManager: NSObject, ObservableObject {
    public static let shared = BLEManager()

    // MARK: - GATT IDs (from the ABMate SDK source: CompanionService.swift)
    // The SDK's CompanionService defines the REAL ABMate GATT profile, and
    // its compiled constants are: mainServiceUUID = "FDB3",
    // mainDataWriteUuid = "FF17" (commands out), mainDataReadUuid = "FF18"
    // (data in), ctkdUuid = "FF20" (classic-BT pairing trigger; unused here
    // because classicBT is disabled). This MATCHES the glasses' firmware,
    // which exposes exactly one service: FDB3. The earlier 128-bit UUIDs
    // (B6632277-...) belong to a different protocol generation and are kept
    // only as legacy fallbacks.
    public static let serviceUUID = CBUUID(string: "FDB3")
    public static let writeUUID   = CBUUID(string: "FF17")
    public static let notifyUUID  = CBUUID(string: "FF18")
    public static let ctkdUUID    = CBUUID(string: "FF20")

    // MARK: - Hotspot protocol constants (AIBudsFoundation, verified)
    /// HotspotMode.ap raw value (foundation: station = 0, ap = 1,
    /// wifiDirect = 2). Earlier payloads of 0x00 selected STATION mode —
    /// the likely root cause of the erratic AP behavior.
    private static let hotspotModeAPByte: UInt8 = 0x01
    /// HotspotState.hotspotOpen raw value (foundation: hotspotClose = 0,
    /// hotspotOpen = 1) — the "AP is up" signal on the 0x10 notification.
    private static let hotspotStateOpenByte: UInt8 = 0x01
    /// HotspotConfigField TLV field IDs of the hotspot configuration payload
    /// (foundation: mode = 0x01, ssid = 0x02, password = 0x03, channel = 0x04).
    private static let hotspotFieldMode: UInt8 = 0x01
    private static let hotspotFieldSSID: UInt8 = 0x02
    private static let hotspotFieldPassword: UInt8 = 0x03
    private static let hotspotFieldChannel: UInt8 = 0x04
    /// Wi-Fi channel requested for the glasses' AP.
    private static let hotspotChannel: UInt8 = 6

    /// Fixed hotspot name requested from the glasses. Per the firmware
    /// developer's contract the app chooses the AP name itself (ASCII, at
    /// least 8 bytes — "MT5GLASSES" is 10). The name is transmitted through
    /// the official hotspot configuration — the SDK's
    /// `DeviceHotspotAPI.configureHotspot(withMode:channel:ssid:password:)`
    /// or the raw TLV frame built from the HotspotConfigField field IDs —
    /// NOT as a plain-text 0x10 payload: the 0x10 payload byte is the
    /// hotspot MODE (0x00 station / 0x01 AP), which is why neither the old
    /// 0x00 payload nor a raw SSID string ever produced an SSID announcement.
    /// If the glasses report their own name anyway (0x10 notification or the
    /// SDK's `didReceiveHotspotAddress`), the reported name takes precedence.
    public static let preferredHotspotSSID = "MT5GLASSES"

    /// Legacy 128-bit ABMate profile (older SDK documentation generation).
    private static let legacyServiceUUID = CBUUID(string: "B6632277-0642-458B-A7A0-23FB1DC92C93")
    private static let legacyWriteUUID   = CBUUID(string: "B6632278-0642-458B-A7A0-23FB1DC92C93")
    private static let legacyNotifyUUID  = CBUUID(string: "B6632279-0642-458B-A7A0-23FB1DC92C93")

    /// Additional known service UUIDs accepted during generic selection.
    private static let fallbackServiceUUIDs: [CBUUID] = [legacyServiceUUID]

    /// Standard GATT services that can never be the ABMate data service.
    /// Used only as the last resort when neither the SDK's nor a legacy UUID
    /// is present in the peripheral's service list.
    private static let standardServiceUUIDs: Set<CBUUID> = [
        CBUUID(string: "1800"), // Generic Access
        CBUUID(string: "1801"), // Generic Attribute
        CBUUID(string: "1802"), // Immediate Alert
        CBUUID(string: "1803"), // Link Loss
        CBUUID(string: "1804"), // Tx Power
        CBUUID(string: "1805"), // Current Time
        CBUUID(string: "1806"), // Reference Time Update
        CBUUID(string: "1807"), // Next DST Change
        CBUUID(string: "1808"), // Glucose
        CBUUID(string: "1809"), // Health Thermometer
        CBUUID(string: "180A"), // Device Information
        CBUUID(string: "180D"), // Heart Rate
        CBUUID(string: "180E"), // Phone Alert Status
        CBUUID(string: "180F"), // Battery
        CBUUID(string: "1811"), // Alert Notification
        CBUUID(string: "1812"), // Human Interface Device
        CBUUID(string: "1813"), // Scan Parameters
        CBUUID(string: "1814"), // Running Speed and Cadence
        CBUUID(string: "1815"), // Automation IO
        CBUUID(string: "1816"), // Cycling Speed and Cadence
        CBUUID(string: "1818"), // Cycling Power
        CBUUID(string: "1819"), // Location and Navigation
        CBUUID(string: "181A"), // Environmental Sensing
        CBUUID(string: "181B"), // Body Composition
        CBUUID(string: "181C"), // User Data
        CBUUID(string: "181D"), // Weight Scale
        CBUUID(string: "181E"), // Bond Management
        CBUUID(string: "181F"), // Continuous Glucose
        CBUUID(string: "1820"), // Internet Protocol Support
        CBUUID(string: "1821"), // Indoor Positioning
        CBUUID(string: "1822"), // Pulse Oximeter
        CBUUID(string: "1823"), // HTTP Proxy
        CBUUID(string: "1824"), // Transport Discovery
        CBUUID(string: "1825")  // Object Transfer
    ]

    /// AIBuds manufacturer IDs (mirrors AIBudsFoundation.ManufacturerID / the diagnostic rig).
    private static let knownManufacturerIDs: Set<UInt16> = [
        0x5442, 0x5444, 0x545A, 0x4854, 0x5851, 0x5A52, 0x5A47,
        0x0600, 0x5452, 0xC001, 0x5A43, 0x4206, 0x5A4D
    ]

    // MARK: - Connection state machine
    public enum ConnectionState {
        case idle          // Not trying to connect
        case scanning      // Looking for the glasses
        case connecting    // BLE link being established
        case discovering   // Services / characteristics / notifications
        case ready         // Ready to send ABMate commands
        case reconnecting  // Waiting to retry after a loss
    }

    @Published public var state: ConnectionState = .idle
    /// Legacy connection flag kept for existing UI. Prefer `isDeviceConnected`.
    @Published public var isConnected: Bool = false
    /// Reactive device-connection state for the UI debug banner.
    /// Kept in sync with `isConnected` until the legacy flag is removed.
    @Published public var isDeviceConnected: Bool = false
    /// Reactive SDK-initialization state for the UI debug banner.
    /// Set from the app's startup path via `setSDKInitialized(_:)`.
    @Published public var isSDKInitialized: Bool = false
    @Published public var isReady: Bool = false
    @Published public var hotspotSSID: String = ""
    @Published public var batteryLevel: Int = 0
    @Published public var statusMessage: String = "Deconectat"
    /// Every device seen during the current SDK scan session, for the manual
    /// device picker (strongest signal first).
    @Published public var discoveredPeripherals: [DiscoveredDevice] = []
    /// When false, the app never connects automatically; the user picks the
    /// glasses from `discoveredPeripherals` in the manual device picker.
    @Published public var isAutoConnectEnabled: Bool = true
    /// When true, the SDK connection enables the classic Bluetooth (SPP)
    /// profile in ConnectParams. Optional experiment, default false. Takes
    /// effect on the NEXT connect (the handshake runs once per link).
    @Published public var isClassicBTEnabled: Bool = false

    // MARK: - Tuning
    private let scanTimeout: TimeInterval = 12.0
    private let connectTimeout: TimeInterval = 15.0
    private let maxReconnectAttempts = 8
    private let reconnectBaseDelay: TimeInterval = 1.5
    private let maxReconnectDelay: TimeInterval = 8.0
    private let hotspotWatchdogDelay: TimeInterval = 8.0
    // 5 attempts: transient failures (hotspot still booting, network not yet
    // visible) need room, while permanent permission errors (codes 7/8)
    // bypass this budget entirely — see connectGlassesWiFi.
    private let maxHotspotRetries = 5
    /// How often the link-liveness monitor reconciles the published
    /// connection flags with the REAL CoreBluetooth peripheral state, and
    /// installs the delegate multiplexer after the SDK takeover.
    private let linkLivenessInterval: TimeInterval = 2.0
    /// How long after the SDK connect to wait for `deviceDidReady` before
    /// logging the pointed handshake diagnostic (log-only; the connect
    /// timeout is the enforcement backstop).
    private let sdkHandshakeWatchdogDelay: TimeInterval = 10.0
    /// Delay between the hotspot configuration and the live-streaming mode
    /// entry (0x12), mirroring the SDK's configureHotspot ->
    /// enterLiveStreamingMode ordering.
    private let liveStreamingModeEntryDelay: TimeInterval = 0.6
    /// Delay between the mode entry and the first Wi-Fi join attempt,
    /// emulating the SDK's waitingForHotspotOpen phase. The join's own
    /// verify/retry loop covers longer AP bring-up times.
    private let hotspotOpenWaitDelay: TimeInterval = 1.5
    /// Post-join hedge window: if the RTSP server is still not confirmed
    /// this long after a successful join, the 0x12 mode command is re-sent
    /// once (see scheduleRTSPModeFallback).
    private let rtspModeFallbackDelay: TimeInterval = 8.0

    // MARK: - Core Bluetooth
    /// Direct CoreBluetooth manager. Scans for candidate glasses and connects
    /// directly in < 1 second. Once connected and services are discovered,
    /// hands the peripheral to the SDK in the background via delegate multiplexer.
    private var centralManager: CBCentralManager!
    /// The active peripheral. Held for the direct BLE channel: service discovery,
    /// command writes, notification handling, and liveness reconciliation.
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var ctkdCharacteristic: CBCharacteristic?
    /// The service selected as the ABMate data service.
    private var targetService: CBService?
    private var seqNum: UInt8 = 0

    // MARK: - Reconnect / media pipeline bookkeeping
    private var isManualDisconnect = false
    private var reconnectAttempts = 0
    private var scanTimeoutWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var reconnectWorkItem: DispatchWorkItem?
    private var hotspotWatchdogWorkItem: DispatchWorkItem?
    private var hotspotRequested = false
    private var rtspConfirmed = false
    private var hotspotRetryCount = 0
    /// True once the live-streaming mode command (0x12, payload 0x01) has
    /// been sent in the current pipeline cycle. In the SDK-validated order
    /// (LiveStreamingAPI.startRTSPLiveStreaming handler order + the official
    /// demo) the media mode is entered BEFORE the Wi-Fi join — entering it
    /// wakes the multimedia coprocessor, starts the internal RTSP server and
    /// keeps the AP from being torn down seconds after association.
    private var isLiveStreamingModeEntered = false
    /// Hotspot configuration escalation state: 0 = TLV configuration frame
    /// sent (or SDK configuration pending), 1 = simple AP-mode frame sent /
    /// SDK configuration succeeded. Drives the watchdog escalation in
    /// armHotspotWatchdog.
    private var hotspotConfigAttempt = 0
    /// One-shot post-join fallback (see scheduleRTSPModeFallback).
    private var rtspFallbackWorkItem: DispatchWorkItem?
    /// Peripherals discovered during scanning, keyed by identifier.
    private var discoveredPeripheralMap: [UUID: CBPeripheral] = [:]
    /// Advertisement data discovered during scanning, keyed by identifier.
    private var discoveredAdvertisementMap: [UUID: [String: Any]] = [:]
    /// RSSI values discovered during scanning, keyed by identifier.
    private var discoveredRSSIMap: [UUID: NSNumber] = [:]
    /// Buffer for reassembling JPEG photo fragments from characteristic FF18 (cmdKey 0x55).
    private var mediaStreamBuffer: Data = Data()
    /// SDK-found devices backing the manual picker entries, keyed by the
    /// peripheral identifier.
    private var foundDeviceMap: [UUID: FoundDeviceConvertible] = [:]
    /// Password used for the glasses' hotspot (default 12345678, overridable
    /// through the manual Wi-Fi sheet). Also transmitted to the glasses
    /// through the hotspot configuration so the AP accepts it.
    private var manualWiFiPassword = "12345678"
    /// Timestamp of the last RTSP start command, used to debounce the multiple
    /// triggers that can request the stream (Wi-Fi connectivity sink, device
    /// ready callback, Wi-Fi join completion, manual Settings button).
    private var lastRTSPRequestAt: Date?
    /// Subscription to HotspotManager connectivity changes.
    private var wifiCancellable: AnyCancellable?
    /// The AIBuds SDK device reported through `deviceDidReady` (registered by
    /// AppSDKDelegate in SmartGlassesApp). Required to call the SDK's feature
    /// APIs — `DeviceCameraAPI.requestPhotoTaking(withCaptureMode: .ai)` for
    /// the BLE photo snapshot, and `DeviceHotspotAPI.configureHotspot` for
    /// the official hotspot configuration.
    private var sdkDevice: DeviceConvertible?
    /// The SDK device currently being connected. Held from candidate
    /// discovery until deviceDidReady promotes it to `sdkDevice`, so the
    /// connect timeout can disconnect it on a stalled attempt.
    private var connectingSDKDevice: DeviceConvertible?
    /// Guards the ready sequence (flags + media pipeline) so it runs exactly
    /// once per link — no matter which signal completes it first
    /// (`deviceDidReady`, the forwarded subscription callback, or the
    /// reconcile catch-all).
    private var hasCompletedReadySequence = false
    /// 0x55 media-stream diagnostics: running fragment counter (included in
    /// every log line so the stream structure is readable in the export) and
    /// the "JPEG stream in progress" flag (set on the SOI marker FF D8,
    /// cleared on the EOI marker FF D9 or when the pipeline resets). See
    /// handleMediaStreamFragment.
    private var mediaStreamFragmentCount = 0
    private var isJPEGStreamInProgress = false

    // MARK: - Link liveness bookkeeping
    /// Repeating reconciliation timer (see `startLinkLivenessMonitor`).
    private var linkLivenessTimer: DispatchSourceTimer?
    /// Installed peripheral-delegate multiplexer (see reconcileDelegates).
    private var peripheralMultiplexer: PeripheralDelegateMultiplexer?

    override init() {
        super.init()
        // Power-state monitor only — see the property documentation above.
        centralManager = CBCentralManager(delegate: self, queue: .main)

        // React to Wi-Fi connectivity no matter HOW it was established
        // (NEHotspotConfiguration, the in-app manual sheet, or a manual join
        // through iOS Settings): as soon as the glasses' network becomes
        // reachable and the device is ready, start the RTSP stream. This is
        // what keeps the pipeline working when NEHotspotConfiguration cannot
        // (missing Hotspot Configuration entitlement) and the user joins the
        // hotspot from the iOS Settings app instead.
        wifiCancellable = HotspotManager.shared.$isConnectedToWiFi
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self = self, connected, self.isReady else { return }
                self.debugLog("Wi-Fi connectivity detected — starting RTSP stream.", level: .wifi)
                self.startRTSPStream()
            }

        // Reconcile the published connection flags with the real CoreBluetooth
        // state every few seconds (see startLinkLivenessMonitor). This is what
        // keeps the BLE badge truthful and the raw ABMate pipeline fed even
        // after the SDK takes over the peripheral delegate.
        startLinkLivenessMonitor()
    }

    // MARK: - Debug logging

    /// Console debug log with the `[DEBUG - BLE]` tag, mirrored into the
    /// in-app DebugLogView so every stage is visible on-device without
    /// Xcode attached.
    private func debugLog(_ message: String, level: DebugLogLevel = .info) {
        print("[DEBUG - BLE] \(message)")
        DebugLogger.shared.log(message, level: level)
    }

    // MARK: - Public API

    /// Stores the AIBuds SDK initialization result (called from the app's
    /// startup path in SmartGlassesApp) and logs it.
    public func setSDKInitialized(_ initialized: Bool) {
        isSDKInitialized = initialized
        debugLog(
            "SDK initialization state updated: \(initialized ? "initialized" : "NOT initialized")",
            level: initialized ? .info : .error
        )
    }

    /// Registers the SDK device reported by the `deviceDidReady` delegate
    /// callback (called from AppSDKDelegate in SmartGlassesApp). Pass nil to
    /// clear the registration when the device disconnects; the stale device
    /// is told to disconnect so the SDK's internal state resets for the next
    /// connection.
    public func setSDKDevice(_ device: DeviceConvertible?) {
        let staleDevice = sdkDevice
        sdkDevice = device
        if let device = device {
            device.delegate = AppSDKDelegate.shared
            // The ready handshake completed — the pending connect (if any) is
            // now the registered device.
            connectingSDKDevice = nil
            debugLog("SDK device registered (deviceDidReady) — BLE AI snapshot available.")

            // Diagnostic protocol inspection: check exact capabilities of this hardware firmware
            if let streaming = device as? LiveStreamingAPI {
                let rtspSupport = streaming.supportsRTSPLiveStreaming
                let jpegSupport = streaming.supportsJPEGImageLiveStreaming
                debugLog("[HARDWARE DIAGNOSTIC] LiveStreamingAPI supported: supportsRTSPLiveStreaming=\(rtspSupport), supportsJPEGImageLiveStreaming=\(jpegSupport)", level: .wifi)
            } else {
                debugLog("[HARDWARE DIAGNOSTIC] Device does NOT conform to LiveStreamingAPI (firmware does not expose live stream protocol)", level: .error)
            }
            if let _ = device as? DeviceMediaFileImportAPI {
                debugLog("[HARDWARE DIAGNOSTIC] DeviceMediaFileImportAPI supported (firmware supports Wi-Fi media file import / album sync)", level: .wifi)
            }
            if let _ = device as? DeviceHotspotAPI {
                debugLog("[HARDWARE DIAGNOSTIC] DeviceHotspotAPI supported (firmware supports Wi-Fi hotspot configuration)", level: .wifi)
            }
            if let _ = device as? DeviceCameraAPI {
                debugLog("[HARDWARE DIAGNOSTIC] DeviceCameraAPI supported (firmware supports photo/video capture over BLE)", level: .info)
            }

            // The SDK handshake completed — attach the raw ABMate channel
            // immediately from the peripheral's service tree (the SDK has
            // discovered it by now), then grant readiness. The liveness
            // monitor recovers the channel later if this early pass is too
            // early (services not yet populated).
            recoverRawChannelFromPeripheral()
            completeReadySequence()
        } else {
            if let staleDevice = staleDevice {
                // Best-effort: the underlying peripheral is usually already
                // gone; this resets the SDK device's connection state so a
                // later connection can create a fresh one.
                staleDevice.disconnect()
            }
            debugLog("SDK device cleared.")
        }
    }

    /// True when the BLE AI snapshot path is usable: the BLE link is ready (FF17 write / FF18 notify active).
    /// The app triggers capture directly via hardware command 0x21 (and SDK if available) and reassembles
    /// incoming JPEG fragments from 0x55 into GlassesPhotoStore.
    public var canRequestAISnapshot: Bool {
        isReady
    }

    // MARK: - SDK connection lifecycle hooks (forwarded from AppSDKDelegate)

    /// The SDK reports that its connection succeeded (DeviceDelegate.didConnectedToDevice).
    /// Log-only: the direct CoreBluetooth connection is already active and managing readiness.
    public func handleSDKConnected() {
        debugLog("SDK device connection reported by delegate (background handoff active).")
    }

    /// The SDK reports a failed connect (didFailToConnectDevice).
    /// Log-only: direct CoreBluetooth link remains active and unaffected.
    public func handleSDKConnectFailed() {
        connectingSDKDevice = nil
        debugLog("SDK background connect failed — direct CoreBluetooth connection remains primary.", level: .info)
    }

    /// The SDK device disconnected (DeviceDelegate.didDisconnectWithError).
    /// Clears the SDK device reference; the direct CoreBluetooth peripheral link remains primary
    /// unless the physical Bluetooth link disconnected (handled by centralManager didDisconnectPeripheral).
    public func handleSDKDeviceDisconnected() {
        connectingSDKDevice = nil
        setSDKDevice(nil)
        debugLog("SDK device detached — direct CoreBluetooth connection remains primary.", level: .info)
    }

    // MARK: - SDK hotspot events (forwarded from AppSDKDelegate)

    /// Handles the SDK's `didHotspotStateChanged` callback (forwarded from
    /// AppSDKDelegate). Per the foundation constants: rawValue 1 =
    /// HotspotState.hotspotOpen, 0 = hotspotClose. The open state is the
    /// authoritative "AP is up" signal that triggers the Wi-Fi join.
    public func handleSDKHotspotState(rawValue: Int) {
        guard isReady else { return }
        if rawValue == Int(Self.hotspotStateOpenByte) {
            if hotspotSSID.isEmpty {
                hotspotSSID = Self.preferredHotspotSSID
            }
            guard !HotspotManager.shared.isConnectedToWiFi else { return }
            debugLog("SDK reports the hotspot OPEN — joining '\(hotspotSSID)'.", level: .wifi)
            connectGlassesWiFi()
        } else {
            debugLog("SDK reports hotspot state \(rawValue) (0 = closed).", level: .wifi)
        }
    }

    /// Handles the SDK's `didReceiveHotspotAddress` callback (forwarded from
    /// AppSDKDelegate). The address may be the network name, the gateway IP
    /// or a URL — it is logged in full, and when it looks like a plain
    /// network name it is adopted as the authoritative SSID.
    public func handleSDKHotspotAddress(_ address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        debugLog("SDK reported hotspot address: '\(trimmed)'.", level: .wifi)
        let looksLikePlainName = !trimmed.contains(".") && !trimmed.contains(":") && !trimmed.contains("/")
        if looksLikePlainName, trimmed.count >= 8, trimmed != hotspotSSID {
            debugLog("Adopting the SDK-reported hotspot name '\(trimmed)' as the SSID.", level: .wifi)
            hotspotSSID = trimmed
        }
    }

    // MARK: - SDK background handoff

    /// Hands the ALREADY-connected peripheral to the AIBuds SDK in the background.
    /// The link liveness monitor and delegate multiplexer ensure this runs alongside
    /// the direct BLE channel without interrupting it.
    private func attachSDKDevice(peripheral: CBPeripheral) {
        guard isReady else { return }
        guard sdkDevice == nil else {
            debugLog("SDK handoff skipped — an SDK device is already registered.")
            return
        }

        let advertisement = discoveredAdvertisementMap[peripheral.identifier]
        let rssi = discoveredRSSIMap[peripheral.identifier]

        // Path 1: standard factory
        var device = AIBudsSDK.makeStorableDeviceFromDiscovered(
            peripheral,
            central: centralManager,
            advertisement: advertisement,
            rssi: rssi
        )
        if device != nil {
            debugLog("SDK device created through makeStorableDeviceFromDiscovered.")
        } else {
            // Path 2: direct construction via classForDeviceModel
            debugLog("makeStorableDeviceFromDiscovered returned nil — trying direct construction via ABMateSDK.shared.classForDeviceModel...")
            let deviceClass = ABMateSDK.shared.classForDeviceModel
            device = deviceClass.init(peripheral: peripheral, advertisementData: advertisement)
            if device != nil {
                debugLog("SDK device created DIRECTLY via classForDeviceModel (isKnownDevice bypassed).")
            }
        }

        guard let device = device else {
            debugLog("SDK handoff skipped: neither factory nor direct initializer created a device.", level: .info)
            return
        }

        debugLog("SDK device created for peripheral '\(device.name)' — setting delegate and registering.")
        device.delegate = AppSDKDelegate.shared
        self.setSDKDevice(device)
    }

    /// Requests an AI snapshot over BLE (no Wi-Fi, no Hotspot Configuration
    /// entitlement needed):
    ///
    /// 1. Registers wait in GlassesPhotoStore.shared.awaitNextPhoto.
    /// 2. If the SDK device with camera API is available, calls requestPhotoTaking.
    /// 3. Sends the hardware photo capture commands (0xE1 & 0x21) directly
    ///    to characteristic FF17.
    /// 4. When the glasses stream JPEG fragments back on FF18 (cmdKey 0xE3 / 0x55),
    ///    handleMediaStreamFragment reassembles them from SOI (FF D8) to EOI (FF D9)
    ///    and calls GlassesPhotoStore.shared.store, completing the wait.
    public func requestAISnapshot(timeout: TimeInterval = 12.0, completion: @escaping (UIImage?, String?) -> Void) {
        guard isReady else {
            DispatchQueue.main.async { completion(nil, "Ochelarii nu sunt conectați (BLE).") }
            return
        }

        debugLog("Requesting AI snapshot over BLE (CaptureMode.ai)...")

        // Register the wait BEFORE sending the command so a fast photo cannot
        // be missed. It completes exactly once: with the photo, with a
        // delegate error, or with a timeout.
        GlassesPhotoStore.shared.awaitNextPhoto(timeout: timeout) { image, errorMessage in
            completion(image, errorMessage)
        }

        // 1. If SDK camera API is available, invoke it in parallel:
        if let device = sdkDevice, let cameraDevice = device as? DeviceCameraAPI {
            debugLog("Invoking cameraDevice.requestPhotoTaking(withCaptureMode: .ai) via SDK...")
            cameraDevice.requestPhotoTaking(withCaptureMode: .ai) { [weak self] success, statusCode, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if success {
                        self.debugLog("SDK AI snapshot command acknowledged (statusCode \(statusCode?.intValue ?? 0)).")
                    } else {
                        let message = Self.snapshotFailureMessage(statusCode: statusCode, error: error)
                        self.debugLog("SDK AI snapshot request reported error: \(message) — raw channel continues awaiting fragments.", level: .error)
                    }
                }
            }
        }

        // 2. Send both ABMate 0xE1 and direct 0x21 photo capture commands:
        debugLog("Sending hardware photo capture commands (0xE1 & 0x21) to characteristic FF17...")
        sendABMateCommand(cmdKey: 0xE1, cmdType: 0x01, payload: Data([0x01]))
        sendABMateCommand(cmdKey: 0x21, cmdType: 0x01, payload: Data([0x01]))
    }

    /// Maps a failed `requestPhotoTaking` result to a user-facing message,
    /// including the firmware status codes documented by the SDK
    /// (0x5001 Bad Command, 0x5002 Storage Full, 0x5004 No Data Transfer
    /// Channel, 0x5005 Status Conflict / Device Busy).
    ///
    /// `error` is typed `Error?` (not `NSError?`): the SDK's
    /// `AIBudsStatusCodeCompletionHandler` block imports its `NSError *`
    /// parameter as `(any Error)?` in Swift, so accepting `Error?` matches
    /// the completion's actual argument type.
    private static func snapshotFailureMessage(statusCode: NSNumber?, error: Error?) -> String {
        if let error = error {
            return "Eroare BLE: \(error.localizedDescription)"
        }
        guard let code = statusCode?.intValue, code != 0 else {
            return "Comanda de captură a fost refuzată de ochelari."
        }
        switch code {
        case 0x5001:
            return "Comandă neacceptată de firmware (0x5001 Bad Command)."
        case 0x5002:
            return "Stocarea ochelarilor este plină (0x5002 Storage Full)."
        case 0x5004:
            return "Canalul de transfer date nu este disponibil (0x5004)."
        case 0x5005:
            return "Ochelarii sunt ocupați cu altă operație (0x5005 Status Conflict) — reîncercați în câteva secunde."
        default:
            return "Ochelarii au refuzat captura (cod \(code))."
        }
    }

    /// Starts (or restarts) the full connection flow: direct scan -> candidate -> direct connect -> ready.
    public func startConnectionFlow() {
        isManualDisconnect = false
        reconnectAttempts = 0
        resetPipelineState()
        discoveredPeripherals.removeAll()
        discoveredPeripheralMap.removeAll()
        discoveredAdvertisementMap.removeAll()
        discoveredRSSIMap.removeAll()
        foundDeviceMap.removeAll()
        startScanning()
    }

    /// Starts CoreBluetooth scanning for candidate smart glasses.
    public func startScanning() {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Bluetooth oprit"
            debugLog("Cannot start scanning — Bluetooth is not powered on (raw state: \(centralManager.state.rawValue)).", level: .error)
            return
        }
        guard state != .ready, state != .discovering, state != .connecting else { return }

        state = .scanning
        statusMessage = "Căutare ochelari..."
        debugLog("Direct BLE scan started (unfiltered, candidates validated on discovery).")
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scheduleScanTimeout()
    }

    public func stopScanning() {
        scanTimeoutWorkItem?.cancel()
        if centralManager.isScanning {
            centralManager.stopScan()
            debugLog("Direct BLE scanning stopped.")
        }
    }

    public func disconnect() {
        isManualDisconnect = true
        debugLog("Manual disconnect requested.")
        cancelTimers()
        stopScanning()
        resetPipelineState()
        connectingSDKDevice?.disconnect()
        connectingSDKDevice = nil
        setSDKDevice(nil)
        targetService = nil
        hasCompletedReadySequence = false
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        ctkdCharacteristic = nil
        state = .idle
        isConnected = false
        isDeviceConnected = false
        isReady = false
        statusMessage = "Deconectat"
    }

    /// Full media pipeline: hotspot configuration -> live streaming mode ->
    /// Wi-Fi join -> RTSP. Safe to call again.
    public func establishMediaPipeline() {
        guard isReady else {
            statusMessage = "Ochelarii nu sunt gata (BLE)"
            debugLog("Cannot establish media pipeline — device not ready (BLE).", level: .error)
            return
        }
        resetPipelineState()
        requestHotspotAP()
    }

    // MARK: - Manual selection (fallback when auto-discovery fails)

    /// Connects to a device the user picked manually from the discovered list.
    public func connect(to device: DiscoveredDevice) {
        guard centralManager.state == .poweredOn else {
            statusMessage = "Bluetooth oprit"
            debugLog("Manual connect failed — Bluetooth is not powered on.", level: .error)
            return
        }
        guard let target = discoveredPeripheralMap[device.id] else {
            statusMessage = "Dispozitivul nu mai este disponibil. Reîncercați scanarea."
            debugLog("Manual connect failed — peripheral \(device.id) is no longer known. Rescan and pick again.", level: .error)
            return
        }

        isManualDisconnect = false
        reconnectAttempts = 0
        stopScanning()

        self.peripheral = target
        state = .connecting
        statusMessage = "Conectare manuală la \(device.name)..."
        debugLog("Manual direct connect to '\(device.name)' (\(device.id.uuidString)).")
        target.delegate = self
        scheduleConnectTimeout()
        centralManager.connect(target, options: nil)
    }

    /// Manual Wi-Fi fallback: joins the glasses' hotspot with user-supplied
    /// credentials when the requested SSID never comes up (or the glasses
    /// broadcast a different name). Does not require an active BLE
    /// connection — the RTSP stream command is sent as soon as the device
    /// becomes ready (or can be fired manually from Settings).
    public func connectWiFiManually(ssid: String, password: String) {
        let trimmedSSID = ssid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSSID.isEmpty else {
            statusMessage = "SSID invalid"
            debugLog("Manual Wi-Fi connect failed — empty SSID.", level: .error)
            return
        }

        manualWiFiPassword = password.isEmpty ? "12345678" : password
        debugLog("Manual Wi-Fi connect to '\(trimmedSSID)'.", level: .wifi)
        rtspConfirmed = false
        hotspotSSID = trimmedSSID
        connectGlassesWiFi()
    }

    // MARK: - ABMate Packet Construction
    /// Format: [seqNum (1B) | cmdKey (1B) | cmdType (1B) | frameSeqNum (1B) | totalFrames (1B) | payload]
    private func sendABMateCommand(cmdKey: UInt8, cmdType: UInt8 = 0x01, payload: Data = Data()) {
        guard let peripheral = peripheral, let writeChar = writeCharacteristic, peripheral.state == .connected else {
            statusMessage = "Eroare: Ochelari neconectați"
            debugLog("Communication error — cannot send command 0x\(String(cmdKey, radix: 16)): device not connected.", level: .error)
            return
        }

        seqNum = seqNum &+ 1
        var packet = Data([seqNum, cmdKey, cmdType, 0x00, 0x01])
        packet.append(payload)

        let writeType: CBCharacteristicWriteType = writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        peripheral.writeValue(packet, for: writeChar, type: writeType)
        debugLog("TX command 0x\(String(cmdKey, radix: 16)) type 0x\(String(cmdType, radix: 16)) seq \(seqNum).", level: .tx)
    }

    // MARK: - Glasses Commands

    /// Public entry point of the media pipeline. Runs the SDK-validated
    /// sequence: hotspot configuration -> live streaming mode entry -> wait
    /// for the open signal -> Wi-Fi join -> RTSP.
    public func requestHotspotAP() {
        guard isReady else {
            statusMessage = "Eroare: Ochelari neconectați"
            debugLog("Cannot request hotspot AP — device not ready.", level: .error)
            return
        }
        startHotspotSequence()
    }

    /// Media pipeline step 1: configure the glasses' hotspot (name +
    /// password + AP mode + channel), then move on to the mode entry. The
    /// configuration phase is best-effort — the mode entry below is what
    /// wakes the multimedia coprocessor and opens the AP.
    private func startHotspotSequence() {
        hotspotRequested = true
        statusMessage = "Configurare Hotspot AP..."
        configureGlassesHotspot { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.liveStreamingModeEntryDelay) { [weak self] in
                self?.enterLiveStreamingModeAndJoin()
            }
        }
    }

    /// Configures the glasses' hotspot with the app-chosen name and password.
    ///
    /// Primary path: the SDK's official `DeviceHotspotAPI.configureHotspot`
    /// (available once the SDK handshake produced a ready device). The AP
    /// mode is constructed through `HotspotMode(rawValue: 1)` — ap = 1 per
    /// the foundation constants — so the call does not depend on enum case
    /// names.
    ///
    /// Fallback (no SDK device): the raw TLV frame on 0x10, payload encoded
    /// with the HotspotConfigField field IDs. If the firmware stays silent,
    /// the watchdog escalates once to the simple AP-mode frame (payload 0x01).
    private func configureGlassesHotspot(completion: @escaping (Bool) -> Void) {
        if let device = sdkDevice, let hotspotDevice = device as? DeviceHotspotAPI {
            // HotspotMode.ap == 1 per the foundation constants; built through
            // rawValue so the implementation does not depend on case names.
            guard let apMode = HotspotMode(rawValue: 1) else {
                debugLog("HotspotMode(rawValue: 1) unavailable on this SDK build — using the raw 0x10 TLV configuration.", level: .error)
                sendRawHotspotConfiguration()
                completion(false)
                return
            }
            debugLog("Configuring the glasses' hotspot through the SDK (DeviceHotspotAPI.configureHotspot, mode=ap(1), channel=\(Self.hotspotChannel), ssid='\(Self.preferredHotspotSSID)').", level: .wifi)
            hotspotDevice.configureHotspot(withMode: apMode, channel: Int(Self.hotspotChannel), ssid: Self.preferredHotspotSSID, password: manualWiFiPassword) { [weak self] success, statusCode, error in
                // Do not assume the callback queue (public reference rule).
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if success {
                        self.debugLog("SDK hotspot configuration accepted (statusCode \(statusCode?.intValue ?? 0)) — SSID '\(Self.preferredHotspotSSID)' and password set.", level: .wifi)
                        self.hotspotSSID = Self.preferredHotspotSSID
                        // The SDK owns the configuration — the watchdog skips
                        // the raw escalation and goes straight to join retries.
                        self.hotspotConfigAttempt = 1
                        completion(true)
                    } else {
                        let reason = error?.localizedDescription ?? "statusCode \(statusCode?.intValue ?? -1)"
                        self.debugLog("SDK hotspot configuration refused (\(reason)) — falling back to the raw 0x10 TLV frame.", level: .error)
                        self.sendRawHotspotConfiguration()
                        completion(false)
                    }
                }
            }
            return
        }

        if sdkDevice == nil {
            debugLog("SDK device not available (no deviceDidReady) — using the raw 0x10 TLV hotspot configuration.", level: .wifi)
        } else {
            debugLog("SDK device does not implement DeviceHotspotAPI — using the raw 0x10 TLV hotspot configuration.", level: .wifi)
        }
        sendRawHotspotConfiguration()
        completion(false)
    }

    /// Raw ABMate fallback for the hotspot configuration: a TLV payload on
    /// the 0x10 command built from the HotspotConfigField field IDs
    /// (mode = 0x01, ssid = 0x02, password = 0x03, channel = 0x04), each
    /// field encoded as [fieldID][valueLength][value...]. The full frame is
    /// hex-logged so a firmware that expects a different framing is
    /// immediately visible in the debug log.
    private func sendRawHotspotConfiguration() {
        let payload = Self.hotspotConfigTLVPayload(
            mode: Self.hotspotModeAPByte,
            ssid: Self.preferredHotspotSSID,
            password: manualWiFiPassword,
            channel: Self.hotspotChannel
        )
        debugLog("Sending raw hotspot configuration (TLV: mode=\(Self.hotspotModeAPByte), ssid='\(Self.preferredHotspotSSID)', channel=\(Self.hotspotChannel)): \(Self.hexDescription(payload)).", level: .tx)
        sendABMateCommand(cmdKey: 0xE6, payload: payload)
        if hotspotSSID.isEmpty {
            hotspotSSID = Self.preferredHotspotSSID
        }
    }

    /// Builds the hotspot configuration TLV payload.
    private static func hotspotConfigTLVPayload(mode: UInt8, ssid: String, password: String, channel: UInt8) -> Data {
        var payload = Data()
        func appendField(_ fieldID: UInt8, _ value: Data) {
            payload.append(fieldID)
            payload.append(UInt8(value.count))
            payload.append(value)
        }
        appendField(hotspotFieldMode, Data([mode]))
        appendField(hotspotFieldSSID, Data(ssid.utf8))
        appendField(hotspotFieldPassword, Data(password.utf8))
        appendField(hotspotFieldChannel, Data([channel]))
        return payload
    }

    /// Media pipeline step 2: enter the live streaming mode BEFORE the Wi-Fi
    /// join, then join. In the SDK-validated sequence
    /// (LiveStreamingAPI.startRTSPLiveStreaming handler order and the official
    /// demo) the media mode is entered while the hotspot is being configured
    /// and BEFORE the phone connects — entering it wakes the multimedia
    /// coprocessor, starts the internal RTSP server and keeps the AP from
    /// being torn down seconds after association.
    private func enterLiveStreamingModeAndJoin() {
        guard isReady else { return }
        if !isLiveStreamingModeEntered {
            isLiveStreamingModeEntered = true
            statusMessage = "Intrare în modul live streaming..."
            sendABMateCommand(cmdKey: 0xE8, cmdType: 0x01, payload: Data([0x01]))
            debugLog("Live streaming mode entry sent (0xE8 payload 0x01) BEFORE the Wi-Fi join — SDK-validated order (enterLiveStreamingMode precedes connectDeviceHotspot).", level: .wifi)
        }
        if HotspotManager.shared.isConnectedToWiFi {
            // Already joined (e.g. a manual join from a previous session) —
            // start the stream right away.
            startRTSPStream()
            return
        }
        // Emulate the SDK's waitingForHotspotOpen phase: give the AP time to
        // open (the open signal arrives through didHotspotStateChanged /
        // didReceiveHotspotAddress / the 0x10 notification), then join. The
        // join's own verification and retry loop cover longer bring-up times.
        statusMessage = "Așteptarea deschiderii hotspot-ului..."
        DispatchQueue.main.asyncAfter(deadline: .now() + hotspotOpenWaitDelay) { [weak self] in
            guard let self = self, self.isReady else { return }
            guard !HotspotManager.shared.isConnectedToWiFi else {
                self.startRTSPStream()
                return
            }
            self.connectGlassesWiFi()
        }
        armHotspotWatchdog()
    }

    public func startRTSPStream() {
        guard isReady else {
            statusMessage = "Eroare: Ochelari neconectați"
            debugLog("Cannot start RTSP stream — device not ready.", level: .error)
            return
        }
        // Debounce: several triggers can fire within milliseconds of each
        // other (connectivity sink + ready callback + Wi-Fi join completion).
        // rtspConfirmed only becomes true when the device acknowledges with
        // 0x12, so a time-based debounce prevents duplicate 0x12 commands
        // while keeping the manual Settings button functional.
        if let last = lastRTSPRequestAt, Date().timeIntervalSince(last) < 5.0 {
            // Debounced command, but make sure the local RTSP client is
            // running anyway — start() is idempotent and its retry loop
            // tolerates the glasses' server not being up yet.
            RTSPClient.shared.start()
            return
        }
        lastRTSPRequestAt = Date()
        statusMessage = "Pornire stream RTSP..."

        // 1. If the SDK device implements LiveStreamingAPI, invoke the official SDK method:
        if let device = sdkDevice, let streamingDevice = device as? LiveStreamingAPI, streamingDevice.supportsRTSPLiveStreaming {
            debugLog("Invoking official SDK startRTSPLiveStreaming...", level: .wifi)
            streamingDevice.startRTSPLiveStreaming(
                withParams: .default,
                configureHotspotStartingHandler: { [weak self] in
                    self?.debugLog("[SDK STREAM] Configuring hotspot...", level: .wifi)
                },
                hotspotConfigureCompletionHandler: { [weak self] success, error in
                    self?.debugLog("[SDK STREAM] Hotspot configured: success=\(success), error=\(error?.localizedDescription ?? "none")", level: .wifi)
                },
                enterLiveStreamingModeStartingHandler: { [weak self] in
                    self?.debugLog("[SDK STREAM] Entering live-stream mode...", level: .wifi)
                },
                enterLiveStreamingModeCompletedHandler: { [weak self] success, error in
                    self?.debugLog("[SDK STREAM] Live-stream mode entered: success=\(success), error=\(error?.localizedDescription ?? "none")", level: .wifi)
                },
                waitingForHotspotOpenHandler: { [weak self] in
                    self?.debugLog("[SDK STREAM] Waiting for device hotspot to open...", level: .wifi)
                },
                connectDeviceHotspotStartingHandler: { [weak self] ssid in
                    self?.debugLog("[SDK STREAM] Connecting to hotspot '\(ssid)'...", level: .wifi)
                },
                deviceHotspotConnectCompletionHandler: { [weak self] success, error in
                    self?.debugLog("[SDK STREAM] Hotspot connect result: success=\(success), error=\(error?.localizedDescription ?? "none")", level: .wifi)
                },
                rtspAddressReceivedHandler: { [weak self] address in
                    self?.debugLog("[SDK STREAM] Authoritative RTSP address received from glasses: '\(address)'", level: .wifi)
                    DispatchQueue.main.async {
                        if let url = URL(string: address) {
                            RTSPClient.shared.start(url: url)
                        } else {
                            RTSPClient.shared.start()
                        }
                    }
                },
                sessionStartCompletionHandler: { [weak self] success, error in
                    self?.debugLog("[SDK STREAM] Live streaming session start: success=\(success), error=\(error?.localizedDescription ?? "none")", level: .wifi)
                },
                sessionFinishHandler: { [weak self] userStopped, error in
                    self?.debugLog("[SDK STREAM] Live streaming session finished: userStopped=\(userStopped), error=\(error?.localizedDescription ?? "none")", level: .wifi)
                }
            )
        }

        // 2. Direct hardware fallback: send 0xE8 command to characteristic FF17
        sendABMateCommand(cmdKey: 0xE8, cmdType: 0x01, payload: Data([0x01]))

        // Start local RTSP client
        RTSPClient.shared.start()
    }

    public func startMicrophoneRecording() {
        guard isReady else {
            statusMessage = "Eroare: Ochelari neconectați"
            debugLog("Cannot start microphone recording — device not ready.", level: .error)
            return
        }
        statusMessage = "Pornire microfon AI..."
        sendABMateCommand(cmdKey: 0xB1, cmdType: 0x01, payload: Data([0x00]))
    }

    private var lastClassicBTWakeTime: Date?

    /// Wakes up the Classic Bluetooth (A2DP / HFP) audio radio in the glasses' firmware
    /// so the glasses can connect to the iPhone as audio headphones / speakers.
    public func triggerClassicBTAudio(force: Bool = false) {
        guard let peripheral = peripheral, let ctkd = ctkdCharacteristic else {
            debugLog("triggerClassicBTAudio skipped — peripheral or CTKD (FF20) not available.")
            return
        }
        if !force, let last = lastClassicBTWakeTime, Date().timeIntervalSince(last) < 5.0 {
            return
        }
        lastClassicBTWakeTime = Date()
        let writeType: CBCharacteristicWriteType = ctkd.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        debugLog("Waking Classic Bluetooth Audio via CTKD FF20 write [0x01]...", level: .tx)
        peripheral.writeValue(Data([0x01]), for: ctkd, type: writeType)
        if ctkd.properties.contains(.read) {
            peripheral.readValue(for: ctkd)
        }
    }

    // MARK: - Media pipeline helpers

    private func connectGlassesWiFi() {
        let ssid = hotspotSSID
        debugLog("Requesting Wi-Fi join for hotspot '\(ssid)'...", level: .wifi)
        HotspotManager.shared.connectToGlassesHotspot(ssid: ssid, password: manualWiFiPassword) { [weak self] success in
            guard let self = self else { return }
            if success {
                self.hotspotRetryCount = 0
                if self.isReady {
                    self.statusMessage = "Wi-Fi Conectat. Pornire RTSP..."
                    self.debugLog("Wi-Fi connected to hotspot '\(ssid)'. Starting RTSP...", level: .wifi)
                    self.startRTSPStream()
                    // One-shot hedge: if the RTSP server is still not
                    // confirmed shortly after the join, re-send the live
                    // streaming mode command once (covers firmware that
                    // drops the mode entry when it arrives before the AP
                    // finished opening).
                    self.scheduleRTSPModeFallback()
                } else {
                    // Manual Wi-Fi joined before BLE is ready: the RTSP start
                    // command is sent automatically once the device becomes
                    // ready (see completeReadySequence and the connectivity
                    // sink in init).
                    self.statusMessage = "Wi-Fi Conectat. Se așteaptă conexiunea BLE..."
                    self.debugLog("Wi-Fi connected to hotspot '\(ssid)' — waiting for BLE readiness before starting RTSP.", level: .wifi)
                }
            } else if let code = HotspotManager.shared.lastJoinErrorCode,
                      code == 7 || code == 8 {
                // Permanent iOS permission failure (missing Hotspot
                // Configuration entitlement on Sideloadly / CI-re-signed
                // builds, or a denied one-time prompt). Retrying apply() can
                // NEVER succeed, so the retry budget is preserved. The phone
                // may ALREADY be joined to the glasses' hotspot (manual join
                // through iOS Settings) — HotspotManager has already probed
                // the gateway for exactly that case. Start the RTSP pipeline
                // anyway: RTSPClient's retry loop confirms real reachability,
                // and the connectivity monitor detects a later manual join
                // and keeps the status up to date.
                self.hotspotRetryCount = 0
                self.statusMessage = "iOS nu permite configurarea Wi-Fi (code \(code)). Dacă telefonul este deja conectat la rețeaua ochelarilor, stream-ul pornește acum; altfel conectați-vă din Setări → Wi-Fi (parolă 12345678)."
                self.debugLog("Wi-Fi join impossible (permission error code \(code)) — skipping apply() retries; starting the RTSP pipeline anyway (works when the phone is already joined).", level: .error)
                self.startRTSPStream()
                self.scheduleRTSPModeFallback()
            } else {
                self.statusMessage = "Conectare Wi-Fi eșuată. Reîncercare..."
                self.debugLog("Wi-Fi join failed for hotspot '\(ssid)' — retry scheduled.", level: .error)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.retryHotspotConnection()
                }
            }
        }
    }

    private func retryHotspotConnection() {
        guard isReady else { return }
        guard hotspotRetryCount < maxHotspotRetries else {
            statusMessage = "Pipeline media indisponibil după \(maxHotspotRetries) încercări. Conectați-vă manual din Setări iOS → Wi-Fi la '\(Self.preferredHotspotSSID)' (parolă 12345678) sau folosiți „Wi-Fi manual\" din aplicație."
            debugLog("Media pipeline unavailable after \(maxHotspotRetries) attempts.", level: .error)
            return
        }
        hotspotRetryCount += 1
        debugLog("Hotspot retry \(hotspotRetryCount)/\(maxHotspotRetries).", level: .wifi)
        if hotspotSSID.isEmpty {
            // Defensive: the SSID is always prefilled by the configuration
            // step in the normal flow; an empty value here means the pipeline
            // was reset mid-flight — restart the sequence.
            hotspotRequested = false
            requestHotspotAP()
        } else {
            connectGlassesWiFi()
        }
    }

    private func armHotspotWatchdog() {
        hotspotWatchdogWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isReady else { return }
            guard !HotspotManager.shared.isConnectedToWiFi else { return }
            if self.hotspotConfigAttempt == 0 {
                // No open signal and no response to the TLV configuration
                // frame: escalate once to the simple AP-mode frame (payload
                // 0x01 = HotspotMode.ap), then wait one more watchdog period
                // before the join retries begin.
                self.hotspotConfigAttempt = 1
                self.debugLog("No hotspot response within the watchdog window — escalating to the simple AP-mode frame (0xE6 payload 0x01).", level: .wifi)
                self.sendABMateCommand(cmdKey: 0xE6, payload: Data([Self.hotspotModeAPByte]))
                self.armHotspotWatchdog()
            } else {
                self.retryHotspotConnection()
            }
        }
        hotspotWatchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hotspotWatchdogDelay, execute: work)
    }

    /// One-shot hedge: if the RTSP server is still not confirmed this long
    /// after the join, re-send the live streaming mode command (0xE8) once.
    /// Covers firmware that drops the mode entry when it arrives before the
    /// AP finished opening.
    private func scheduleRTSPModeFallback() {
        rtspFallbackWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.isReady else { return }
            guard !self.rtspConfirmed else { return }
            self.debugLog("RTSP still unconfirmed \(Int(self.rtspModeFallbackDelay))s after the join — re-sending the live streaming mode command (0xE8) once.", level: .wifi)
            sendABMateCommand(cmdKey: 0xE8, cmdType: 0x01, payload: Data([0x01]))
        }
        rtspFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + rtspModeFallbackDelay, execute: work)
    }

    private func resetPipelineState() {
        hotspotRequested = false
        rtspConfirmed = false
        hotspotRetryCount = 0
        hotspotSSID = ""
        lastRTSPRequestAt = nil
        isLiveStreamingModeEntered = false
        hotspotConfigAttempt = 0
        hotspotWatchdogWorkItem?.cancel()
        rtspFallbackWorkItem?.cancel()
        // 0x55 media-stream diagnostics: a pipeline reset also ends any
        // in-flight photo/audio stream.
        mediaStreamFragmentCount = 0
        isJPEGStreamInProgress = false
        mediaStreamBuffer.removeAll()
    }

    private func cancelTimers() {
        scanTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem?.cancel()
        reconnectWorkItem?.cancel()
        hotspotWatchdogWorkItem?.cancel()
        rtspFallbackWorkItem?.cancel()
    }

    // MARK: - Link liveness reconciliation
    // The published connection flags (isConnected / isDeviceConnected / isReady)
    // are normally driven by callbacks. With the SDK end-to-end flow the SDK
    // installs itself as the peripheral's delegate — early callbacks never
    // reach BLEManager until the multiplexer is installed. This monitor
    // (a) wraps the SDK's peripheral-delegate takeover in a multiplexer so
    // BOTH consumers keep receiving callbacks, (b) reconciles the flags with
    // the REAL CBPeripheral.state every 2 seconds, (c) recovers the RX/TX
    // pair from the peripheral's own service tree when the SDK's discovery
    // callbacks were missed, and (d) completes the ready sequence when the
    // notify channel is observable — following the SDK docs' golden rule:
    // never assume device state — reconcile it through properties.

    private func startLinkLivenessMonitor() {
        guard linkLivenessTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + linkLivenessInterval, repeating: linkLivenessInterval)
        timer.setEventHandler { [weak self] in
            self?.reconcileLinkState()
        }
        timer.resume()
        linkLivenessTimer = timer
    }

    private func reconcileLinkState() {
        // 1) Delegate reconciliation: the SDK owns the peripheral delegate;
        //    wrap it in a multiplexer so both the SDK (handshake, photo
        //    reassembly) and BLEManager (raw ABMate parsing) receive
        //    callbacks.
        reconcileDelegates()

        guard let currentPeripheral = peripheral else { return }
        let linkUp = currentPeripheral.state == .connected

        // 2) Passive characteristic recovery: the SDK drives discovery, and
        //    its callbacks may fire BEFORE the multiplexer was installed —
        //    recover the RX/TX pair from the peripheral's own service tree so
        //    the raw pipeline and the ready catch-all can function.
        if linkUp, isDeviceConnected, notifyCharacteristic == nil,
           let services = currentPeripheral.services, !services.isEmpty {
            let svc = services.first { $0.uuid == Self.serviceUUID }
                ?? services.first { Self.fallbackServiceUUIDs.contains($0.uuid) }
            if let svc = svc {
                if targetService == nil { targetService = svc }
                if let characteristics = svc.characteristics, !characteristics.isEmpty {
                    debugLog("Reconcile recovered the ABMate characteristics from the service tree (discovery callbacks were missed pre-multiplexer).")
                    attachRawChannel(from: characteristics, serviceUUID: svc.uuid)
                }
            }
        }

        // 3) Ready catch-all: if the SDK subscribed to the notify
        //    characteristic before the multiplexer was installed, the
        //    forwarded subscription callback was missed — complete the ready
        //    sequence as soon as the channel is observable.
        if linkUp, isDeviceConnected, !hasCompletedReadySequence,
           let notify = notifyCharacteristic, notify.isNotifying {
            debugLog("Ready catch-all: notify channel is live (subscription callback was missed pre-multiplexer).")
            completeReadySequence()
        }

        // 4) Reconcile the published flags with the real peripheral state.
        if !linkUp, isDeviceConnected {
            // The BLE link is actually gone but the flags still say connected:
            // the disconnect callback was swallowed (typically by the SDK
            // delegate takeover). Reset everything and rebuild the connection
            // exactly like an unexpected loss.
            debugLog("State reconciled: the BLE link is DOWN while the UI still showed connected — the disconnect callback was missed. Resetting the connection state.", level: .error)
            forceLinkDownCleanup()
        } else if linkUp, !isDeviceConnected {
            // The link came back outside our flow (e.g. the SDK auto-
            // reconnected after a drop). Reflect reality in the UI; readiness
            // is only granted by completeReadySequence.
            debugLog("State reconciled: the BLE link is UP while the UI showed disconnected — updating the badge.")
            reconnectWorkItem?.cancel()
            isConnected = true
            isDeviceConnected = true
        }
    }

    /// Detects the SDK's peripheral-delegate takeover and installs/refreshes
    /// the multiplexer, so neither consumer loses the callback stream.
    private func reconcileDelegates() {
        if let current = peripheral?.delegate, !(current === self) {
            if current === peripheralMultiplexer {
                // Already multiplexed — nothing to do.
            } else if let mux = peripheralMultiplexer {
                // The SDK replaced our multiplexer with a new handler —
                // re-wrap the new handler in the existing multiplexer.
                mux.second = current
                peripheral?.delegate = mux
                debugLog("SDK replaced the peripheral delegate again — re-wrapped in the multiplexer.")
            } else {
                let mux = PeripheralDelegateMultiplexer()
                mux.first = self
                mux.second = current
                peripheralMultiplexer = mux
                peripheral?.delegate = mux
                debugLog("SDK took over the peripheral delegate — installed a multiplexer so BOTH the SDK (handshake, photo reassembly) and the raw ABMate pipeline receive notifications.")
            }
        }
    }

    /// Drops all link-derived state after the liveness monitor proved the
    /// peripheral is disconnected — the callback-driven equivalent of the
    /// SDK's disconnect cleanup.
    private func forceLinkDownCleanup() {
        connectTimeoutWorkItem?.cancel()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        targetService = nil
        isConnected = false
        isDeviceConnected = false
        isReady = false
        hasCompletedReadySequence = false
        connectingSDKDevice = nil
        setSDKDevice(nil)
        state = .idle

        if isManualDisconnect {
            statusMessage = "Deconectat"
            return
        }

        resetPipelineState()
        statusMessage = "Conexiune BLE pierdută (detectat prin verificare). Reconectare..."
        scheduleReconnect()
    }

    // MARK: - Candidate validation (mirrors the diagnostic rig)

    private func isCandidateGlasses(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        // 1) Advertised ABMate service UUID — the SDK's CompanionService
        //    UUID (FDB3) or a legacy variant.
        if let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           services.contains(Self.serviceUUID) || services.contains(where: { Self.fallbackServiceUUIDs.contains($0) }) {
            return true
        }

        // 2) Local name keywords.
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let upper = name.uppercased()
        if upper.contains("MT5") || upper.contains("GLASSES") || upper.contains("ABMATE") {
            return true
        }

        // 3) Manufacturer data: known AIBuds company ID + XOR-masked MAC.
        //    iOS layout: [companyID lo, companyID hi, payload...]
        //    MAC[i] = payload[5 + i] ^ 0xAD  =>  data[7 + i] ^ 0xAD
        //    (Matches the SDK's isKnownDevice unpacking: productId at [2..3],
        //    protocolVersion at [4], MAC at [5..10] XOR 0xAD.)
        if let man = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, man.count >= 2 {
            let manufacturerID = UInt16(man[0]) | (UInt16(man[1]) << 8)
            guard Self.knownManufacturerIDs.contains(manufacturerID) else { return false }
            if man.count >= 13 {
                let macBytes = (0..<6).map { man[7 + $0] ^ 0xAD }
                return macBytes.contains(where: { $0 != 0 })
            }
            return true
        }

        return false
    }

    /// Inserts or refreshes a discovered device (newest RSSI wins) and keeps
    /// the list ordered by signal strength for the manual picker.
    private func upsertDiscovered(_ device: DiscoveredDevice) {
        if let index = discoveredPeripherals.firstIndex(where: { $0.id == device.id }) {
            discoveredPeripherals[index] = device
        } else {
            discoveredPeripherals.append(device)
        }
        discoveredPeripherals.sort { $0.rssi > $1.rssi }
    }

    // MARK: - Timers

    private func scheduleScanTimeout() {
        scanTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.state == .scanning else { return }
            if self.centralManager.isScanning {
                self.centralManager.stopScan()
            }
            if self.isAutoConnectEnabled {
                self.statusMessage = "Ochelari negăsiți. Reîncercare..."
                self.debugLog("Scan timed out — no glasses found. Scheduling reconnect.", level: .error)
                self.scheduleReconnect()
            } else {
                // Manual mode: stop scanning but keep the discovered list on
                // screen so the user can pick the glasses or rescan explicitly.
                self.statusMessage = "Scanare oprită. Selectați ochelarii din listă sau reîncercați."
                self.debugLog("Scan timed out — manual selection mode keeps the discovered list.")
            }
        }
        scanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeout, execute: work)
    }

    private func scheduleConnectTimeout() {
        connectTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            // Covers both a pending connect (.connecting) and a stalled
            // post-connect handshake (.discovering) — readiness marks the
            // attempt as done.
            guard !self.isReady else { return }
            guard self.state == .connecting || self.state == .discovering else { return }
            self.statusMessage = "Timeout conectare. Reîncercare..."
            self.debugLog("Connect timeout — cancelling connection attempt.", level: .error)
            if let connecting = self.connectingSDKDevice {
                connecting.disconnect()
                self.connectingSDKDevice = nil
            }
            if let peripheral = self.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            self.scheduleReconnect()
        }
        connectTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout, execute: work)
    }

    private func scheduleReconnect() {
        guard !isManualDisconnect else { return }
        guard reconnectAttempts < maxReconnectAttempts else {
            state = .idle
            statusMessage = "Conectare eșuată după \(maxReconnectAttempts) încercări. Verificați ochelarii."
            debugLog("Connection failed after \(maxReconnectAttempts) attempts — giving up.", level: .error)
            return
        }
        reconnectAttempts += 1
        let delay = min(reconnectBaseDelay * Double(reconnectAttempts), maxReconnectDelay)
        state = .reconnecting
        statusMessage = "Reconectare în \(Int(delay))s (încercarea \(reconnectAttempts)/\(maxReconnectAttempts))..."
        debugLog("Reconnect scheduled in \(Int(delay))s (attempt \(reconnectAttempts)/\(maxReconnectAttempts)).")
        reconnectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.startScanning()
        }
        reconnectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - Characteristic helpers

    /// Human-readable property list for the discovery diagnostics.
    private static func propertyNames(_ properties: CBCharacteristicProperties) -> String {
        var names: [String] = []
        if properties.contains(.broadcast) { names.append("broadcast") }
        if properties.contains(.read) { names.append("read") }
        if properties.contains(.writeWithoutResponse) { names.append("writeNoRsp") }
        if properties.contains(.write) { names.append("write") }
        if properties.contains(.notify) { names.append("notify") }
        if properties.contains(.indicate) { names.append("indicate") }
        return names.isEmpty ? "none" : names.joined(separator: "|")
    }

    /// Space-separated hex dump used in notification diagnostics
    /// ("a1 b2 ..."), or "(empty)" for a zero-length payload.
    private static func hexDescription(_ data: Data) -> String {
        guard !data.isEmpty else { return "(empty)" }
        return data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Attaches the raw ABMate channel (RX/TX pair) from an
    /// already-discovered characteristic list. The SDK drives discovery and
    /// subscribes to FF18 as part of its ready handshake; the pair is
    /// captured by PROPERTIES (with UUID preference) so the raw pipeline
    /// (hotspot commands, battery, 0x55 media diagnostics) works alongside
    /// the SDK. If the notify characteristic is not yet notifying, we
    /// subscribe ourselves as well — a duplicate subscription is a no-op at
    /// the CoreBluetooth level, and an early subscription guarantees the raw
    /// channel comes up even if the SDK handshake stalls.
    private func attachRawChannel(from characteristics: [CBCharacteristic], serviceUUID: CBUUID) {
        let notifiable: (CBCharacteristic) -> Bool = {
            $0.properties.contains(.notify) || $0.properties.contains(.indicate)
        }
        let writable: (CBCharacteristic) -> Bool = {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }

        let notifyChar = characteristics.first { $0.uuid == Self.notifyUUID && notifiable($0) }
            ?? characteristics.first { $0.uuid == Self.legacyNotifyUUID && notifiable($0) }
            ?? characteristics.first(where: notifiable)
        let writeChar = characteristics.first { $0.uuid == Self.writeUUID && writable($0) }
            ?? characteristics.first { $0.uuid == Self.legacyWriteUUID && writable($0) }
            ?? characteristics.first(where: writable)

        notifyCharacteristic = notifyChar
        writeCharacteristic = writeChar
        if notifyChar == nil {
            debugLog("WARNING: no notifiable characteristic captured from \(serviceUUID.uuidString) — the raw ABMate channel stays unavailable.", level: .error)
        }
        if let notifyChar = notifyChar, !notifyChar.isNotifying {
            peripheral?.setNotifyValue(true, for: notifyChar)
            debugLog("Subscribing to \(notifyChar.uuid.uuidString) ourselves (the SDK has not subscribed yet).")
        }
        debugLog("Raw ABMate channel attached: RX \(notifyChar?.uuid.uuidString ?? "NONE") / TX \(writeChar?.uuid.uuidString ?? "NONE") from \(serviceUUID.uuidString).")
        statusMessage = "Canal ABMate atașat..."
        maybeStartMediaPipeline()
    }

    // MARK: - Ready sequence (exactly once per link)

    /// Grants readiness and starts the automatic media pipeline. Runs exactly
    /// once per link (guarded by hasCompletedReadySequence); the trigger can
    /// be our direct subscription callback or the reconcile catch-all.
    private func completeReadySequence() {
        guard !hasCompletedReadySequence else { return }
        hasCompletedReadySequence = true

        reconnectAttempts = 0
        state = .ready
        isConnected = true
        isDeviceConnected = true
        isReady = true
        statusMessage = "Gata de utilizare"
        debugLog("Device ready — direct CoreBluetooth connection live (FF17 write / FF18 notify active).")

        maybeStartMediaPipeline()
        startLinkLivenessMonitor()
        triggerClassicBTAudio()

        // Background SDK handoff (passive, delayed so it does not interleave with initial ready sequence):
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, let current = self.peripheral else { return }
            self.attachSDKDevice(peripheral: current)
        }
    }

    /// Starts the automatic media pipeline (hotspot configuration -> live
    /// streaming mode -> Wi-Fi -> RTSP) once BOTH readiness signals are in:
    /// the device is ready AND the raw ABMate channel (RX/TX) is attached.
    /// Called from completeReadySequence and attachRawChannel — whichever
    /// happens last triggers the start.
    private func maybeStartMediaPipeline() {
        guard isReady else { return }
        guard notifyCharacteristic != nil, writeCharacteristic != nil else {
            debugLog("Media pipeline deferred — the raw ABMate channel is not attached yet.")
            return
        }
        if hotspotRequested {
            // The pipeline is already running; just make sure the RTSP client
            // is up if Wi-Fi is already established.
            if HotspotManager.shared.isConnectedToWiFi {
                startRTSPStream()
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.requestHotspotAP()
        }
    }

    /// Recovers the raw ABMate channel (RX/TX pair) directly from the
    /// peripheral's service tree right after `deviceDidReady`. The SDK has
    /// completed its discovery by then, so the FDB3 service and its
    /// characteristics are usually already populated; if this early pass is
    /// too early (services/characteristics not yet populated), the
    /// link-liveness monitor retries the same recovery within its next
    /// 2-second pass (see reconcileLinkState step 2).
    private func recoverRawChannelFromPeripheral() {
        guard let currentPeripheral = peripheral, currentPeripheral.state == .connected else { return }
        // Never clobber an already-attached raw channel.
        guard notifyCharacteristic == nil else { return }
        guard let services = currentPeripheral.services, !services.isEmpty else {
            debugLog("Raw channel recovery deferred — the SDK has not populated services yet (the liveness monitor will retry).")
            return
        }
        let svc = services.first { $0.uuid == Self.serviceUUID }
            ?? services.first { Self.fallbackServiceUUIDs.contains($0.uuid) }
        guard let svc = svc, let characteristics = svc.characteristics, !characteristics.isEmpty else {
            debugLog("Raw channel recovery deferred — ABMate characteristics not discovered yet (the liveness monitor will retry).")
            return
        }
        debugLog("Recovering the raw ABMate channel from the service tree after deviceDidReady.")
        attachRawChannel(from: characteristics, serviceUUID: svc.uuid)
    }

    // MARK: - 0x55 media stream diagnostics

    /// Diagnostic handler for the 0x55 media-stream notification. Each
    /// fragment is classified and the first 16 bytes are hex-dumped so the
    /// payload format can be identified from the exported debug log without
    /// a debugger attached.
    ///
    /// Classification:
    ///   - JPEG START: the fragment begins with the JPEG SOI marker FF D8
    ///     (first fragment of a photo).
    ///   - JPEG continuation: any fragment after a SOI, until the JPEG EOI
    ///     marker FF D9 is observed at a fragment tail (stream end).
    ///   - No JPEG marker: most likely an audio/PCM chunk (e.g. from the 0x14
    ///     microphone session) or an unknown binary format.
    /// Reassembles JPEG photo fragments streaming over BLE (cmdKey 0x55 on characteristic FF18).
    /// Accumulates bytes from JPEG SOI marker (0xFF 0xD8) to JPEG EOI marker (0xFF 0xD9),
    /// Assembles photo data fragments received over BLE into a complete JPEG
    /// and delivers the complete image to GlassesPhotoStore.shared.store(photoData:).
    private func handleMediaStreamFragment(_ rawPayload: Data) {
        guard !rawPayload.isEmpty else { return }

        // ABMate 0xE3 sub-framing:
        // Byte 0 == 0x00: End-of-transfer marker (payload: [0x00, totalBytes (4B LE)])
        // Byte 0 == 0x01: Image data chunk; actual JPEG payload starts at index 1
        if rawPayload[0] == 0x00 && rawPayload.count <= 8 {
            debugLog("0xE3 EOF marker received (\(Self.hexDescription(rawPayload))) — finalizing photo.", level: .rx)
            finalizeJPEGStream()
            return
        }

        let chunk: Data
        if rawPayload[0] == 0x01 && rawPayload.count > 1 {
            chunk = rawPayload.subdata(in: 1..<rawPayload.count)
        } else {
            chunk = rawPayload
        }

        mediaStreamFragmentCount += 1
        let prefixHex = Self.hexDescription(chunk.prefix(16))

        // Check for JPEG SOI (Start Of Image: 0xFF 0xD8)
        if let soiRange = chunk.range(of: Data([0xFF, 0xD8])) {
            isJPEGStreamInProgress = true
            mediaStreamBuffer = chunk.subdata(in: soiRange.lowerBound..<chunk.count)
            debugLog("0xE3 fragment #\(mediaStreamFragmentCount) (\(chunk.count) B) [\(prefixHex)] — JPEG START (SOI FFD8 found, buffer initialized with \(mediaStreamBuffer.count) B).", level: .rx)
        } else if isJPEGStreamInProgress {
            mediaStreamBuffer.append(chunk)
            debugLog("0xE3 fragment #\(mediaStreamFragmentCount) (\(chunk.count) B) [\(prefixHex)] — JPEG continuation (accumulated \(mediaStreamBuffer.count) B).", level: .rx)
        } else {
            debugLog("0xE3 fragment #\(mediaStreamFragmentCount) (\(chunk.count) B) [\(prefixHex)] — no active JPEG stream.", level: .rx)
            return
        }

        // Check for JPEG EOI (End Of Image: 0xFF 0xD9)
        if isJPEGStreamInProgress, mediaStreamBuffer.range(of: Data([0xFF, 0xD9])) != nil {
            finalizeJPEGStream()
        }
    }

    private func finalizeJPEGStream() {
        guard isJPEGStreamInProgress || !mediaStreamBuffer.isEmpty else { return }
        isJPEGStreamInProgress = false

        var completeJPEG = mediaStreamBuffer
        if let eoiRange = mediaStreamBuffer.range(of: Data([0xFF, 0xD9])) {
            completeJPEG = mediaStreamBuffer.subdata(in: 0..<eoiRange.upperBound)
        }
        mediaStreamBuffer.removeAll()

        debugLog("JPEG END detected! Complete image assembled: \(completeJPEG.count) bytes.", level: .rx)
        if UIImage(data: completeJPEG) != nil {
            debugLog("Successfully validated clean JPEG image from BLE stream (\(completeJPEG.count) bytes). Storing in GlassesPhotoStore...", level: .info)
            GlassesPhotoStore.shared.store(photoData: completeJPEG)
        } else {
            debugLog("Assembled \(completeJPEG.count) bytes, but UIImage could not decode it.", level: .error)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            debugLog("Bluetooth powered on.")
            // Resume the flow (initial scan or reconnect wait) unless the user disconnected.
            if !isManualDisconnect, (state == .idle || state == .scanning || state == .reconnecting) {
                startScanning()
            }
        case .poweredOff:
            debugLog("Bluetooth powered off — connection lost.", level: .error)
            cancelTimers()
            isConnected = false
            isDeviceConnected = false
            isReady = false
            hasCompletedReadySequence = false
            connectingSDKDevice = nil
            setSDKDevice(nil)
            targetService = nil
            state = .idle
            statusMessage = "Bluetooth este oprit"
        case .unauthorized:
            debugLog("Bluetooth permission denied (unauthorized). Check Info.plist usage descriptions and Settings.", level: .error)
            cancelTimers()
            state = .idle
            connectingSDKDevice = nil
            setSDKDevice(nil)
            targetService = nil
            statusMessage = "Permisiune Bluetooth refuzată"
        case .unsupported:
            debugLog("Bluetooth unsupported on this device.", level: .error)
            cancelTimers()
            state = .idle
            connectingSDKDevice = nil
            setSDKDevice(nil)
            targetService = nil
            statusMessage = "Bluetooth nesuportat pe acest dispozitiv"
        default:
            statusMessage = "Stare Bluetooth necunoscută"
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi: NSNumber) {
        guard state == .scanning else { return }

        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let displayName = advertisedName.isEmpty
            ? "Fără nume (\(peripheral.identifier.uuidString.prefix(8)))"
            : advertisedName
        upsertDiscovered(DiscoveredDevice(id: peripheral.identifier, name: displayName, rssi: rssi.intValue))
        discoveredPeripheralMap[peripheral.identifier] = peripheral
        discoveredAdvertisementMap[peripheral.identifier] = advertisementData
        discoveredRSSIMap[peripheral.identifier] = rssi

        guard isAutoConnectEnabled else { return }
        guard isCandidateGlasses(peripheral, advertisementData: advertisementData) else { return }

        debugLog("Candidate glasses found: \(displayName) (RSSI \(rssi.intValue)). Stopping scan and connecting directly...")

        scanTimeoutWorkItem?.cancel()
        if central.isScanning {
            central.stopScan()
        }

        self.peripheral = peripheral
        state = .connecting
        statusMessage = "Ochelari găsiți. Conectare..."
        peripheral.delegate = self
        scheduleConnectTimeout()
        centralManager.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        processConnectedPeripheral(peripheral)
    }

    /// Configures link state and initiates service discovery on a newly connected peripheral.
    private func processConnectedPeripheral(_ peripheral: CBPeripheral) {
        connectTimeoutWorkItem?.cancel()
        reconnectAttempts = 0
        isConnected = true
        isDeviceConnected = true
        state = .discovering
        statusMessage = "Conectat la BLE. Descoperire servicii..."
        debugLog("Connection established (<1s) — discovering services...")
        peripheral.delegate = self
        peripheralMultiplexer = nil
        hasCompletedReadySequence = false
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        targetService = nil
        isConnected = false
        isDeviceConnected = false
        isReady = false
        hasCompletedReadySequence = false
        setSDKDevice(nil)
        state = .idle
        if let error = error {
            statusMessage = "Conectare eșuată: \(error.localizedDescription)"
            debugLog("Connection failed: \(error.localizedDescription)", level: .error)
        } else {
            statusMessage = "Conectare eșuată"
            debugLog("Connection failed (no error details).", level: .error)
        }
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectTimeoutWorkItem?.cancel()
        writeCharacteristic = nil
        notifyCharacteristic = nil
        targetService = nil
        isConnected = false
        isDeviceConnected = false
        isReady = false
        hasCompletedReadySequence = false
        setSDKDevice(nil)
        state = .idle

        if isManualDisconnect {
            debugLog("Disconnected (manual).")
            statusMessage = "Deconectat"
            return
        }

        resetPipelineState()
        statusMessage = "Conexiune pierdută. Reconectare..."
        if let error = error {
            debugLog("Unexpected disconnect: \(error.localizedDescription) — rebuilding pipeline.", level: .error)
        } else {
            debugLog("Unexpected disconnect (no error details) — rebuilding pipeline.", level: .error)
        }
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            statusMessage = "Eroare descoperire servicii: \(error.localizedDescription). Reconectare..."
            debugLog("Service discovery error: \(error.localizedDescription) — reconnecting.", level: .error)
            scheduleReconnect()
            return
        }
        let services = peripheral.services ?? []
        let serviceUUIDs = services.map { $0.uuid.uuidString }
        if serviceUUIDs.isEmpty {
            debugLog("Service discovery returned NO services on '\(peripheral.name ?? "?")'.", level: .error)
        } else {
            debugLog("Discovered \(services.count) service(s) on '\(peripheral.name ?? "?")': \(serviceUUIDs.joined(separator: ", ")).")
        }

        let abMateService = services.first { $0.uuid == Self.serviceUUID }
            ?? services.first(where: { Self.fallbackServiceUUIDs.contains($0.uuid) })
        if let target = abMateService {
            targetService = target
            debugLog("ABMate service (FDB3) found — discovering characteristics FF17, FF18...")
            peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID, Self.ctkdUUID], for: target)
        } else if !services.isEmpty {
            debugLog("Discovered services do not include FDB3 [\(serviceUUIDs.joined(separator: ", "))] — discovering characteristics on all non-standard services...")
            for service in services where !Self.standardServiceUUIDs.contains(service.uuid) {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error {
            debugLog("Characteristic discovery error: \(error.localizedDescription).", level: .error)
            return
        }
        guard let characteristics = service.characteristics, !characteristics.isEmpty else {
            debugLog("Service \(service.uuid.uuidString) exposed NO characteristics.", level: .error)
            return
        }

        let described = characteristics
            .map { "\($0.uuid.uuidString) [\(Self.propertyNames($0.properties))]" }
            .joined(separator: ", ")
        debugLog("Characteristics of \(service.uuid.uuidString): \(described).")

        if let ctkd = characteristics.first(where: { $0.uuid == Self.ctkdUUID }) {
            ctkdCharacteristic = ctkd
            debugLog("CTKD characteristic (FF20) present — waking Classic Bluetooth Audio radio...")
            triggerClassicBTAudio()
        }

        guard service.uuid == Self.serviceUUID
            || Self.fallbackServiceUUIDs.contains(service.uuid)
            || targetService == nil else { return }
        targetService = service
        attachRawChannel(from: characteristics, serviceUUID: service.uuid)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic === notifyCharacteristic else { return }
        if let error = error {
            statusMessage = "Eroare abonare notificări: \(error.localizedDescription). Reconectare..."
            debugLog("Notification subscription error: \(error.localizedDescription) — reconnecting.", level: .error)
            scheduleReconnect()
            return
        }
        guard characteristic.isNotifying else { return }

        guard !hasCompletedReadySequence else {
            debugLog("Notification state re-confirmed — ready sequence already completed.")
            return
        }
        debugLog("Notification channel live (\(characteristic.uuid.uuidString) notifying) — completing the ready sequence.")
        completeReadySequence()
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            statusMessage = "Eroare notificare: \(error.localizedDescription)"
            debugLog("Communication error on notification: \(error.localizedDescription)", level: .error)
            return
        }
        guard characteristic === notifyCharacteristic else { return }
        guard let data = characteristic.value, !data.isEmpty else { return }

        // Raw JPEG stream detection (starts with SOI FF D8)
        if data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8 {
            handleMediaStreamFragment(data)
            return
        }

        if data.count >= 5 {
            let rxSeqNum = data[0]
            let cmdKey = data[1]
            let cmdType = data[2]
            let frameSeqNum = data[3]
            let totalFrames = data[4]
            let payload = data.count > 5 ? data.subdata(in: 5..<data.count) : Data()

            // Handle both modern ABMate format (data[1] = cmdKey) and legacy fallback (data[0] = cmdKey)
            let knownKeys: Set<UInt8> = [0xE3, 0xE1, 0xE6, 0xE7, 0xE8, 0x01, 0x02, 0x10, 0x12, 0x21, 0x27, 0x55, 0xB1, 0xB2]
            let effectiveCmdKey = knownKeys.contains(cmdKey) ? cmdKey : (knownKeys.contains(rxSeqNum) ? rxSeqNum : cmdKey)

            if effectiveCmdKey == 0xB2 {
                // High-frequency microphone/audio stream from glasses (50+ packets/sec).
                // Do not dispatch to debugLog on every 160-byte frame to protect main thread.
                return
            }

            debugLog("RX notification seq \(rxSeqNum) cmd 0x\(String(effectiveCmdKey, radix: 16)) type 0x\(String(cmdType, radix: 16)) [\(frameSeqNum)/\(totalFrames)] (\(payload.count) B payload).", level: .rx)

            switch effectiveCmdKey {
            case 0xE3, 0x55: // Photo data notification (photoDataForSceneRecogNotify in ABMate / media stream)
                debugLog("Photo data fragment received (cmd 0x\(String(effectiveCmdKey, radix: 16)), \(payload.count) bytes).", level: .rx)
                handleMediaStreamFragment(payload)

            case 0xE1, 0x21: // Photo capture ack / response from glasses
                debugLog("Photo command response 0x\(String(effectiveCmdKey, radix: 16)) (\(payload.count) bytes): \(Self.hexDescription(payload)).", level: .rx)

            case 0xE7, 0x10: // Hotspot notification / response
                hotspotWatchdogWorkItem?.cancel()
                debugLog("Hotspot notification 0x\(String(effectiveCmdKey, radix: 16)) payload (\(payload.count) bytes): \(Self.hexDescription(payload)).", level: .rx)

                let isPrintableText = !payload.isEmpty && payload.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                let rawString = String(data: payload, encoding: .utf8) ?? ""
                let cleanedSSID = isPrintableText
                    ? rawString.trimmingCharacters(in: CharacterSet(charactersIn: " \r\n\t"))
                    : ""

                if cleanedSSID.count >= 4 {
                    if cleanedSSID != hotspotSSID {
                        debugLog("Hotspot notification reports SSID '\(cleanedSSID)' (requested '\(Self.preferredHotspotSSID)') — using the reported name.", level: .wifi)
                        hotspotSSID = cleanedSSID
                    }
                    statusMessage = "Hotspot activ: \(hotspotSSID). Conectare Wi-Fi..."
                    connectGlassesWiFi()
                } else if let stateByte = payload.first {
                    if hotspotSSID.isEmpty {
                        hotspotSSID = Self.preferredHotspotSSID
                    }
                    if stateByte == Self.hotspotStateOpenByte {
                        debugLog("Hotspot state byte 0x01 (hotspotOpen) — joining '\(hotspotSSID)'.", level: .wifi)
                    } else {
                        debugLog("Hotspot state byte 0x\(String(stateByte, radix: 16)) (not 1) — attempting join anyway.", level: .wifi)
                    }
                    statusMessage = "Hotspot activ: \(hotspotSSID). Conectare Wi-Fi..."
                    connectGlassesWiFi()
                } else {
                    if hotspotSSID.isEmpty {
                        hotspotSSID = Self.preferredHotspotSSID
                    }
                    statusMessage = "Hotspot activ: \(hotspotSSID). Conectare Wi-Fi..."
                    debugLog("Hotspot ack without payload — joining the configured AP name '\(hotspotSSID)'.", level: .wifi)
                    connectGlassesWiFi()
                }

            case 0xE8, 0x12: // Live streaming mode / RTSP status response
                rtspConfirmed = true
                rtspFallbackWorkItem?.cancel()
                self.statusMessage = "RTSP activ la rtsp://192.168.43.1:554/live"
                debugLog("Live streaming / RTSP confirmed (cmd 0x\(String(effectiveCmdKey, radix: 16))).", level: .wifi)

            case 0x02: // Battery status
                if payload.count >= 3 {
                    let candidate = Int(payload[1])
                    self.batteryLevel = (candidate > 0 && candidate <= 100) ? candidate : Int(payload[0])
                } else if let firstByte = payload.first {
                    self.batteryLevel = Int(firstByte)
                }
                self.batteryLevel = min(max(self.batteryLevel, 0), 100)
                debugLog("Battery level updated: \(self.batteryLevel)%.", level: .info)

            case 0x01, 0x27: // Device info response
                debugLog("Device info response 0x\(String(effectiveCmdKey, radix: 16)) (\(payload.count) bytes).", level: .info)

            default:
                break
            }
        } else {
            if isJPEGStreamInProgress || (data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8) {
                handleMediaStreamFragment(data)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            debugLog("Write error on \(characteristic.uuid.uuidString): \(error.localizedDescription)", level: .error)
            return
        }
        if characteristic.uuid == Self.ctkdUUID {
            debugLog("CTKD (FF20) write acknowledged — Classic Bluetooth Audio radio activated on glasses!", level: .info)
        }
    }
}
