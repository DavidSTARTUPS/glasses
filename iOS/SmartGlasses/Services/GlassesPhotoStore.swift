import Foundation
import UIKit

/// Shared store for photos received from the glasses over BLE.
///
/// The AIBuds SDK reassembles the JPEG payload that the glasses stream back
/// in fragments over the BLE notify characteristic and delivers the complete
/// image through the
/// `device(_:didReceivePhotoDataForSceneRecognition:enhancedPhotoData:error:)`
/// delegate callback (implemented in SmartGlassesApp). This store is the
/// bridge between that callback and the rest of the app:
///
/// - `latestPhoto` / `latestPhotoData` — the most recent snapshot, for the
///   UI and for the AI vision request.
/// - `awaitNextPhoto(timeout:completion:)` — used by BLEManager's
///   `requestAISnapshot` to wait for the photo that answers a capture
///   request, with a timeout for the "glasses never sent it" case.
///
/// This is the path that makes the app's core feature ("ask AI what I see")
/// work with Bluetooth only — no Wi-Fi join and no Hotspot Configuration
/// entitlement.
///
/// All state is touched on the main queue only, so the `@Published`
/// mutations and the pending-request bookkeeping stay race-free.
public final class GlassesPhotoStore: ObservableObject {
    public static let shared = GlassesPhotoStore()

    /// Latest complete snapshot, decoded for UI display / AI upload.
    @Published public private(set) var latestPhoto: UIImage?
    /// Latest raw JPEG payload exactly as delivered by the SDK.
    @Published public private(set) var latestPhotoData: Data?
    /// When the latest snapshot arrived (nil until the first one).
    @Published public private(set) var lastPhotoAt: Date?
    /// Last human-readable photo error, surfaced in the chat/status UI.
    @Published public private(set) var lastErrorMessage: String?

    // MARK: - Pending waiters

    /// One `awaitNextPhoto` call. Completes exactly once (photo, delegate
    /// error, or timeout); `finish` returns false on any later attempt so a
    /// late timeout can never double-complete a fulfilled request.
    private final class PendingRequest {
        let completion: (UIImage?, String?) -> Void
        private(set) var isFinished = false

        init(completion: @escaping (UIImage?, String?) -> Void) {
            self.completion = completion
        }

        func finish(with image: UIImage?, message: String?) -> Bool {
            guard !isFinished else { return false }
            isFinished = true
            completion(image, message)
            return true
        }
    }

    private var pendingRequests: [PendingRequest] = []

    private init() {}

    // MARK: - Producer (called from the SDK delegate callback)

    /// Stores a complete JPEG received over BLE and completes every pending
    /// wait with it.
    public func store(photoData: Data) {
        guard let image = UIImage(data: photoData) else {
            reportError("Date foto invalide de la ochelari (JPEG necitibil, \(photoData.count) bytes).")
            return
        }
        DebugLogger.shared.log("BLE photo received (\(photoData.count) bytes).", level: .rx)
        StreamRelayServer.shared.updateFrame(image)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.latestPhotoData = photoData
            self.latestPhoto = image
            self.lastPhotoAt = Date()
            self.lastErrorMessage = nil

            let pending = self.pendingRequests
            self.pendingRequests.removeAll()
            for request in pending {
                _ = request.finish(with: image, message: nil)
            }
        }
    }

    /// Records a photo failure and fails every pending wait with it.
    public func reportError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lastErrorMessage = message
            let pending = self.pendingRequests
            self.pendingRequests.removeAll()
            for request in pending {
                _ = request.finish(with: nil, message: message)
            }
        }
    }

    // MARK: - Consumer (called from BLEManager.requestAISnapshot)

    /// Completes with the next photo that arrives after this call, or with a
    /// failure message when the timeout elapses first. Safe to call from any
    /// queue; the completion always runs on the main queue.
    public func awaitNextPhoto(timeout: TimeInterval, completion: @escaping (UIImage?, String?) -> Void) {
        let request = PendingRequest(completion: completion)

        let register: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.pendingRequests.append(request)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self = self else { return }
                // finish(...) is a no-op when the photo already arrived.
                if request.finish(with: nil, message: "Ochelarii nu au trimis imaginea în \(Int(timeout))s (timeout).") {
                    self.pendingRequests.removeAll { $0 === request }
                }
            }
        }

        if Thread.isMainThread {
            register()
        } else {
            DispatchQueue.main.async(execute: register)
        }
    }
}
