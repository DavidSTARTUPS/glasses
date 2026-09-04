import SwiftUI
import AIBuds
import ABMate

@main
struct SmartGlassesApp: App {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var hotspotManager = HotspotManager.shared

    /// Guards against double initialization: SwiftUI may construct the App
    /// struct more than once, but the SDK must be initialized exactly once.
    private static var sdkInitializeAttempted = false

    init() {
        Self.initializeAIBudsSDK()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(hotspotManager)
        }
    }

    // MARK: - AIBuds SDK Initialization

    /// Initializes the AIBuds SDK once at the app's startup path and verifies
    /// the returned Bool, as required by the public integration reference.
    ///
    /// Modular initialization (ABMate connection provider), per the docs'
    /// "Modular connection initialization" pattern. The LiveStream module is
    /// installed but needs no startup registration.
    ///
    /// The result is published through `BLEManager.isSDKInitialized` so the
    /// UI debug banner can react to it.
    private static func initializeAIBudsSDK() {
        guard !sdkInitializeAttempted else { return }
        sdkInitializeAttempted = true

        print("[DEBUG - SDK] Initializing AIBuds SDK (modular: ABMate + LiveStream)...")

        let configuration = SDKConfiguration.default()
        // The app owns the connection lifecycle end-to-end (scan -> candidate
        // -> SDK connect -> ready -> reconnect backoff). The SDK's built-in
        // auto-reconnect would race BLEManager's reconnect logic and could
        // resurrect a link after the user deliberately disconnected, so it is
        // disabled here.
        configuration.shouldAutoReconnectWhenAppLaunch = false

        let initialized = AIBudsSDK.initialize(
            [ABMateSDK.shared],
            configuration: configuration,
            delegate: AppSDKDelegate.shared
        )

        if initialized {
            print("[DEBUG - SDK SUCCESS] AIBuds SDK initialized successfully.")
        } else {
            print("[DEBUG - SDK ERROR] AIBuds SDK initialization FAILED (returned false).")
            print("[DEBUG - SDK ERROR] Most common cause: missing Bluetooth usage descriptions in Info.plist.")
            print("[DEBUG - SDK ERROR] Verify that BOTH 'NSBluetoothAlwaysUsageDescription' and 'NSBluetoothWhileInUseUsageDescription' are present in the generated Info.plist (they come from 'info.properties' in iOS/project.yml).")
        }

        // Publish the result for the UI debug banner + in-app debug log.
        BLEManager.shared.setSDKInitialized(initialized)
    }
}

// MARK: - AIBuds SDK Delegate

/// Receives AIBuds SDK callbacks. Conforms to BOTH delegate protocols:
///
/// - `SDKDelegate` — the global delegate registered through
///   `AIBudsSDK.initialize`; receives scanning state and connection
///   lifecycle events.
/// - `DeviceDelegate` — the per-device delegate that BLEManager assigns to
///   each SDK device at connect time (SDK-owned mode) or handoff (legacy
///   mode). This is where the BLE photo snapshot JPEG arrives
///   (`didReceivePhotoDataForSceneRecognition`) and where the hotspot events
///   arrive (`didHotspotStateChanged`, `didReceiveHotspotAddress`) — the
///   global delegate alone may never receive per-device data callbacks.
///
/// The overlapping lifecycle methods have identical signatures in both
/// protocols, so a single implementation satisfies both. NOTE: because the
/// shared instance sits on BOTH channels, lifecycle callbacks can be
/// delivered twice (visible as duplicated "started connecting" log lines) —
/// the BLEManager hooks are idempotent, so this is harmless.
///
/// The class is internal (NOT private) so BLEManager — same target — can
/// assign `AppSDKDelegate.shared` as the SDK device's DeviceDelegate. It
/// inherits NSObject because both protocols are Objective-C-backed.
///
/// QUEUE DISCIPLINE: SDK delegate callbacks arrive on an SDK-owned queue
/// that must not be assumed (public reference rule). Every callback that
/// mutates app state (BLEManager's published flags, hotspotSSID, the SDK
/// device registration, the connection state machine) is marshalled to the
/// main queue HERE, at the boundary — so BLEManager's handlers can rely on
/// main-thread execution. Log-only callbacks are safe on any queue
/// (DebugLogger queues internally).
final class AppSDKDelegate: NSObject, SDKDelegate, DeviceDelegate {
    static let shared = AppSDKDelegate()

    /// Console log with the `[DEBUG - SDK]` tag, mirrored into the in-app
    /// DebugLogView so the SDK handshake is visible on-device.
    private func log(_ message: String, level: DebugLogLevel = .info) {
        print("[DEBUG - SDK] \(message)")
        DebugLogger.shared.log(message, level: level)
    }

    // MARK: Scanning state (SDKDelegate)

    func onScanningStatusChanged(_ isScanning: Bool) {
        log("SDK scanning state changed: \(isScanning ? "started" : "stopped").")
    }

    // MARK: Connection lifecycle (SDKDelegate + DeviceDelegate)

    func didStartConnectingDevice(_ device: DeviceConvertible) {
        log("SDK: started connecting to '\(device.name)' (\(device.uuid.uuidString)).")
    }

    func didConnectedToDevice(_ device: DeviceConvertible) {
        // Marshalled to main: drives BLEManager's connection state machine
        // (cancels the connect timeout, moves to discovering).
        DispatchQueue.main.async {
            self.log("SDK: connected to '\(device.name)' — running the ready handshake (MTU / device info / auth).")
            BLEManager.shared.handleSDKConnected()
        }
    }

    func didFailToConnectDevice(_ device: DeviceConvertible?, error: NSError?) {
        // Marshalled to main: schedules the reconnect in SDK-owned mode.
        DispatchQueue.main.async {
            let name = device?.name ?? "?"
            if let error = error {
                self.log("SDK: connect to '\(name)' FAILED: \(error.localizedDescription) (code \(error.code)).", level: .error)
            } else {
                self.log("SDK: connect to '\(name)' FAILED (no error details).", level: .error)
            }
            BLEManager.shared.handleSDKConnectFailed()
        }
    }

    func deviceDidReady(_ device: DeviceConvertible) {
        // Marshalled to main: registers the SDK device in BLEManager, whose
        // state (sdkDevice, canRequestAISnapshot) the UI reads on main.
        DispatchQueue.main.async {
            self.log("deviceDidReady — '\(device.name)' is connected and ready for feature APIs (BLE AI snapshot live).")
            BLEManager.shared.setSDKDevice(device)
        }
    }

    func device(_ device: DeviceConvertible?, didDisconnectWithError error: NSError?) {
        // Marshalled to main: clears BLEManager's SDK device registration and
        // rebuilds the connection (SDK-owned mode).
        DispatchQueue.main.async {
            if let error = error {
                self.log("SDK device '\(device?.name ?? "?")' disconnected with error: \(error.localizedDescription)", level: .error)
            } else {
                self.log("SDK device '\(device?.name ?? "?")' disconnected (no error reported).")
            }
            // The SDK device reference is stale after a disconnect; it is
            // registered again by the next deviceDidReady (after a new
            // connection).
            BLEManager.shared.setSDKDevice(nil)
            BLEManager.shared.handleSDKDeviceDisconnected()
        }
    }

    // MARK: BLE photo snapshot (DeviceDelegate)

    /// Complete JPEG snapshot delivered over BLE (CaptureMode.ai). The SDK
    /// reassembles the fragmented notify payload before this fires — no
    /// Wi-Fi join and no Hotspot Configuration entitlement involved.
    ///
    /// Signature matches the SDK's swiftinterface exactly:
    /// `device(_:didReceivePhotoDataForSceneRecognition:enhancedPhotoData:error:)`
    /// with `Data?`, `Data?`, `NSError?` (NOT `Error?`).
    ///
    /// Thread-safety: GlassesPhotoStore.queue-s all state internally, and
    /// DebugLogger dispatches to main — this callback is safe on any queue.
    func device(
        _ device: DeviceConvertible,
        didReceivePhotoDataForSceneRecognition photoData: Data?,
        enhancedPhotoData: Data?,
        error: NSError?
    ) {
        if let error = error {
            log("photo data error: \(error.localizedDescription)", level: .error)
            GlassesPhotoStore.shared.reportError("Eroare foto de la ochelari: \(error.localizedDescription)")
            return
        }
        guard let photoData = photoData, !photoData.isEmpty else {
            log("photo callback received without data.")
            GlassesPhotoStore.shared.reportError("Ochelarii nu au trimis imaginea (date goale).")
            return
        }
        log("photo data received over BLE (\(photoData.count) bytes).", level: .rx)
        GlassesPhotoStore.shared.store(photoData: photoData)
    }

    func device(
        _ device: DeviceConvertible,
        didReceiveOnDeviceVoiceAssistantAuthResult isSuccess: Bool,
        error: NSError?
    ) {
        let errorText = error.map { ", error: \($0.localizedDescription)" } ?? ""
        log("on-device voice assistant auth result: \(isSuccess ? "success" : "failure")\(errorText)")
    }

    // MARK: Hotspot events (DeviceDelegate)

    /// Hotspot state changes reported by the glasses
    /// (DeviceDelegate.didHotspotStateChanged). Per the foundation
    /// constants: HotspotState rawValue 1 = hotspotOpen, 0 = hotspotClose —
    /// the authoritative "AP is up" signal that triggers the Wi-Fi join in
    /// BLEManager. Only the rawValue is used, so the implementation does not
    /// depend on enum case names.
    ///
    /// Marshalled to main: the handler mutates BLEManager's @Published
    /// hotspotSSID and drives the Wi-Fi join.
    func device(_ device: DeviceConvertible, didHotspotStateChanged state: HotspotState) {
        DispatchQueue.main.async {
            self.log("hotspot state changed (rawValue \(state.rawValue)).", level: .wifi)
            BLEManager.shared.handleSDKHotspotState(rawValue: state.rawValue)
        }
    }

    /// Hotspot address reported by the glasses
    /// (DeviceDelegate.didReceiveHotspotAddress). Forwarded to BLEManager,
    /// which logs it in full and adopts it as the authoritative SSID when it
    /// looks like a plain network name.
    ///
    /// Marshalled to main: the handler may mutate the @Published hotspotSSID.
    func device(_ device: DeviceConvertible, didReceiveHotspotAddress hotspotAddress: String) {
        DispatchQueue.main.async {
            self.log("hotspot address received: '\(hotspotAddress)'.", level: .wifi)
            BLEManager.shared.handleSDKHotspotAddress(hotspotAddress)
        }
    }
}
