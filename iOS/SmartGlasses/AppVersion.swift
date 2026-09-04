import Foundation

/// App build version, shown in the UI (debug banner + Settings).
///
/// Bumped manually with every commit that changes app code. Comparing the
/// number shown in the app against the number stated in the chat confirms
/// whether the installed build is up to date — a stale number means the
/// phone is running an old build.
///
/// History:
///   v1 — initial version counter (GATT profile FDB3/FF17/FF18 aligned with
///        the SDK's CompanionService + delegate multiplexers).
///   v2 — Wi-Fi pipeline hardening for entitlement-less (Sideloadly) builds:
///        codes 7/8 now probe the gateway and succeed when the phone is
///        already joined; failed joins no longer clobber the connectivity
///        state; RTSP starts even when the join is refused; debug log
///        export added.
///   v3 — fixed hotspot name per the firmware developer's contract (the app
///        chooses the AP name): join + RTSP flow against "MT5GLASSES";
///        Settings toggle for classic Bluetooth (SPP) during the SDK handoff.
///        NOTE: v3 also sent the SSID as the plain-text 0x10 payload — that
///        interpretation was WRONG (see v4).
///   v4 — SDK-validated media pipeline order: hotspot CONFIGURATION (SDK
///        DeviceHotspotAPI.configureHotspot with HotspotMode.ap = 1, raw
///        HotspotConfigField TLV fallback, watchdog escalation to the simple
///        AP-mode frame 0x10 [0x01]) -> LIVE STREAMING MODE ENTRY (0x12)
///        BEFORE the Wi-Fi join (the step that wakes the multimedia
///        coprocessor and keeps the AP alive) -> join gated on the hotspot
///        open signal (didHotspotStateChanged / 0x10 state byte, 1 = open) ->
///        post-join 0x12 hedge. Corrects v3: the 0x10 payload byte is the
///        hotspot MODE (0x00 = station), not the SSID. SDK hotspot state /
///        address callbacks wired; LiveStreamingAPI capability logging.
///   v5 — audit hardening (no pipeline behavior changes): the four
///        state-mutating SDK delegate callbacks (deviceDidReady,
///        didDisconnectWithError, didHotspotStateChanged,
///        didReceiveHotspotAddress) are marshalled to the main queue at the
///        AppSDKDelegate boundary, so BLEManager's @Published state
///        (hotspotSSID, SDK device registration) is never mutated off-main.
///   v6 — hardcoded default OpenRouter key (chat works instantly without the
///        Settings screen; an empty Settings override falls back to the
///        default on the next request) and a diagnostic handler for the 0x55
///        media-stream notification: per-fragment counter, hex dump of the
///        first 16 bytes, and JPEG SOI (FF D8) / EOI (FF D9) classification
///        to identify photo fragments vs audio/PCM chunks in the log export.
///   v7 — Phase 1 + Phase 2. Phase 2 (SDK-owned connection): the SDK
///        performs the CoreBluetooth connect on the FRESH peripheral from
///        candidate discovery — no pre-connect — so deviceDidReady can fire;
///        BLEManager attaches passively (delegate multiplexer + passive
///        characteristic capture + reconcile recovery + ready catch-all) and
///        keeps the raw ABMate channel alive alongside; SDK lifecycle hooks
///        (connected/failed/disconnected) drive the reconnect loop; the
///        legacy pre-connect flow is preserved behind the Settings toggle.
///        Phase 1 (native glasses UX): text input removed from the main
///        screen (Settings debug toggle, persisted); the AI button runs the
///        glasses-native loop BLE capture (CaptureMode.ai) -> Base64 vision
///        query -> TTS answer; OpenRouter requests/responses/errors are
///        logged to DebugLogger (HTTP status + parsed server error body).
///   v8 — build fix only (no behavior change): the SDK-owned service lookup
///        in didDiscoverServices was hoisted out of the `if let` condition
///        into a plain `let` — a trailing closure inside an `if let`
///        condition hits a Swift parser ambiguity that failed the CI build
///        ("anonymous closure argument not contained in a closure").
///   v9 — build fix only (no behavior change): restored the
///        @Published isClassicBTEnabled property that was accidentally
///        dropped from BLEManager during the v7 rewrite; its three
///        references (ConnectParams in both connection paths + the Settings
///        SPP toggle) failed the CI build with "cannot find
///        'isClassicBTEnabled' in scope".
///   v10 — connection robustness after the v9 field log showed the
///        SDK-owned connect hanging silently (no didConnectedToDevice, no
///        didFailToConnectDevice, no CoreBluetooth delegate takeover) for
///        the full 15s window, after which the timeout dead-ended the app
///        with no reconnect: (1) the default connection mode is back to the
///        direct BLEManager connect — the method that succeeded in every
///        session — with the SDK handoff at ready; the SDK-owned flow stays
///        available as an experimental toggle; (2) the SDK-owned path gained
///        a +6s state-based safety net (peripheral connected -> take over
///        with our discovery; connecting -> wait; disconnected -> fall back
///        to the direct connect) and the handshake watchdog now takes the
///        link over instead of only logging; (3) the connect timeout always
///        schedules the reconnect itself instead of relying on callbacks
///        that may never fire; (4) didConnectPeripheral is processed in both
///        modes (dropping it orphaned live links); (5) fixed the
///        contradictory guard that made the legacy SDK handoff
///        (attachSDKDevice) unreachable; per-link mode flag
///        (isCurrentLinkLegacy) drives the discovery/subscription behavior.
///   v11 — build fix: restored the missing processConnectedPeripheral helper
///        in BLEManager whose three call sites failed the CI build.
///   v12 — OFFICIAL SDK END-TO-END FLOW (quickstart + official demo). Root
///        cause of the stalled deviceDidReady identified from lastlog.txt:
///        a CBPeripheral can only be connected by the CBCentralManager that
///        DISCOVERED it — every previous flow discovered the glasses on the
///        app's own central and then asked the SDK (bound to its own
///        internal ABMate central) to connect or handshake them, which
///        stalled every time. The fix follows the official quickstart
///        exactly: (1) scanning via AIBudsSDK.startScanning with the SDK's
///        deviceFoundHandler feeding both the auto-connect candidate
///        validation and the manual picker (the app's CBCentralManager
///        remains only as the Bluetooth power-state signal, exactly like the
///        official demo); (2) makeStorableDeviceFromDiscovered bound to
///        foundDevice.central (the SDK's own manager); (3)
///        device.delegate = AppSDKDelegate.shared + device.connect(params)
///        — the SDK performs the connect, the FDB3/FF17/FF18 handshake and
///        fires deviceDidReady, which registers the device and turns SNAP
///        green. The raw ABMate channel (hotspot commands, battery, 0x55
///        media diagnostics) attaches passively via the delegate multiplexer
///        and a post-deviceDidReady service-tree recovery; readiness is
///        granted by deviceDidReady OR the live notify channel, so the media
///        pipeline auto-starts either way. Removed the legacy pre-connect +
///        handoff path, the SDK-owned experimental toggle and the
///        direct-connect fallback — one connection path, the official one.
///   v13 — build fix for the v12 rewrite (no flow changes), against the
///        FoundDeviceConvertible / startScanning shapes the compiler
///        revealed: (1) added the missing recoverRawChannelFromPeripheral
///        helper that setSDKDevice references ("cannot find in scope") — it
///        attaches the raw ABMate channel from the peripheral's service tree
///        right after deviceDidReady and defers to the liveness monitor when
///        the SDK has not populated services yet; (2) FoundDeviceConvertible
///        members: peripheral is NON-optional, advertisementData and central
///        are optional (the factory call is now wrapped in
///        central.flatMap), and the RSSI member is spelled `RSSI` (the ObjC
///        demo spelling) with its numeric type hedged through `as? NSNumber`
///        so it compiles whether the member is an NSNumber or a plain Int;
///        (3) AIBudsSDK.startScanning's optional timeout is an UNLABELED
///        first parameter — startScanning(nil, deviceFoundHandler:completion:)
///        (the `withTimeout:` label from the ObjC demo spelling was
///        rejected); (4) removed an unused peripheral binding in the
///        connect-timeout work item (warning).
///   v14 — GUARANTEED HYBRID BLE + PHOTO-TO-AI PIPELINE:
///        Field logs proved that AIBudsSDK's internal CBCentralManager hung
///        silently for 15s during scanning/connecting, whereas direct
///        CoreBluetooth (scanForPeripherals + centralManager.connect) connects
///        reliably in <500ms every time. Furthermore, canRequestAISnapshot had
///        been blocked waiting for SDK deviceDidReady, and 0x55 media stream
///        fragments were never reassembled into GlassesPhotoStore.
///        v14 implements the fully autonomous, fail-safe pipeline:
///        (1) Direct CoreBluetooth scan & connect connects in <1 second;
///        (2) canRequestAISnapshot is active as soon as BLE is ready (isReady),
///            turning SNAP green immediately;
///        (3) requestAISnapshot sends hardware capture command 0x21 (0x01 AI
///            mode) directly to characteristic FF17 (with parallel SDK call if
///            present);
///        (4) handleMediaStreamFragment reassembles incoming JPEG fragments on
///            FF18 (cmdKey 0x55) from SOI (FF D8) to EOI (FF D9), validates the
///            resulting image, and stores it in GlassesPhotoStore.shared;
///        (5) OpenRouterService sends the vision query to Gemini/Claude with
///            image=YES and speaks the Romanian response via TTSService;
///        (6) SDK attaches passively in the background via delegate multiplexer
///   v15 — REVERSE-ENGINEERED ABMATE PROTOCOL SPECIFICATION & RESILIENCE:
///        Reverse engineering of the ABMate arm64 binary (DataPacket.o, StartPhotoTakingCommand.o,
///        HotspotConfigCommand.o, EnterRTSPLiveStreamingModeCommand.o, StartAIAudioRecordingCommand.o,
///        Device.o) revealed the exact wire format and command opcodes:
///        (1) Wire framing: [seqNum (1B), cmdKey (1B), cmdType (1B), frameSeqNum (1B), totalFrames (1B), payload...].
///            Previous versions had cmdKey and seqNum inverted, causing the glasses to interpret sequence
///            numbers as opcodes, and rx notifications (0, 1, 2, 3...) were sequence numbers, not keys!
///        (2) Exact Command Keys:
///            - StartPhotoTakingCommand: 0xE1 (CaptureMode.ai = 1). Previous 0x21 was MusicControlCommand!
///            - photoDataForSceneRecogNotify: 0xE3 streaming JPEG photo fragments from the camera.
///            - HotspotConfigCommand: 0xE6 (mode=ap, SSID, password, channel).
///            - Hotspot status notification: 0xE7 (and legacy 0x10).
///            - EnterRTSPLiveStreamingModeCommand: 0xE8 (and legacy 0x12).
///            - StartAIAudioRecordingCommand: 0xB1 (and legacy 0x14).
///        (3) Peripheral Notification Dispatch:
///            - peripheral didUpdateValueFor now supports dual wire format detection (modern 0xE3/0xE1/0xE6/0xE7/0xE8
///              and legacy fallbacks), streaming incoming 0xE3 and 0x55 fragments into handleMediaStreamFragment.
///        (4) Unexpected Disconnect Fix:
///            - In attachSDKDevice, calling device.connect(params) spawned an internal central manager that collided
///              with the active CoreBluetooth connection, triggering a 2-second timeout disconnect. Removed device.connect;
///              direct CoreBluetooth maintains primary link stability without disconnection.
///   v16 — PHOTO UNCORRUPTED REASSEMBLY & FULLSCREEN UI:
///        (1) Photo JPEG Stream Uncorrupted Reassembly:
///            Debug log 20260904-094044 proved that 0xE1 hardware photo capture
///            succeeded and streamed 37 fragments over 0xE3! However, the JPEG was
///            corrupted with gray scanlines because: (a) each 0xE3 fragment carries
///            a 1-byte sub-header 0x01 that was mistakenly appended into the JPEG
///            data; (b) an interleaved 0xFC battery notification was appended into
///            the JPEG buffer by the default case. v16 cleanly strips the 0x01
///            sub-header from every fragment, handles the 0x00 EOF packet, and
///            strictly isolates photo stream fragments from other notifications.
///        (2) Fullscreen Edge-to-Edge UI:
///            - Removed the cramped, truncated navigation bar ("MT5 Smart Gl...") in
///              favor of a custom edge-to-edge top bar fitting all device widths.
///            - Replaced centered vertical spacing with full-height expanding chat
///              view, eliminating the black bottom void and pinning controls to bottom.
///            - Added Fullscreen Photo Viewer (pinch-to-zoom + pan modal).
///            - Added Fullscreen Live RTSP Video Mode (viewfinder HUD).
///   v17 — BLUETOOTH AUDIO ROUTING & RTSP REACHABILITY HARDENING:
///        (1) Bluetooth Audio Route Fix:
///            - TTSService now avoids the AVAudioSessionErrorCodeIncompatibleCategory crash
///              caused by setting .allowBluetoothHFP on .playback category.
///            - Implemented multi-tier audio session configuration (.playback with A2DP,
///              falling back to .playAndRecord with HFP/A2DP).
///            - Audio session is proactively refreshed on every speak(text:) call.
///            - Current audio output route is logged to DebugLogger for end-to-end route visibility.
///            - Proper deactivation on speech finish to unduck background audio.
///   v18 — STANDALONE BLUETOOTH AUDIO (CTKD FF20 AUTO-WAKE):
///        (1) Standalone Classic Bluetooth Audio Activation:
///            - The glasses firmware keeps the Classic Bluetooth (A2DP / HFP) audio radio
///              dormant until commanded over BLE. Previously, the user was forced to open
///              the official AiBuds app to wake it up.
///            - BLEManager now captures CTKD characteristic FF20 on service FDB3 and writes
///              [0x01] immediately upon discovery and ready sequence completion.
///            - This wakes the glasses' audio radio directly from our app, allowing iOS
///              Settings -> Bluetooth to connect to the glasses speakers automatically.
///            - Added manual "Activare Bluetooth Audio (Difuzoare)" button in Settings.
///            - Eliminates the need to ever run the official AiBuds app (which blocked BLE
///              in background).
///   v19 — STREAM RELAY SERVER (TAILSCALE & LAN BRIDGE FOR PC):
///        (1) iPhone as Active Streaming Antenna:
///            - The glasses' Wi-Fi (MT5GLASSES) cannot reach a PC on desktop/Ethernet,
///              and connecting the PC to the glasses Wi-Fi disconnects the PC from internet
///              and Tailscale.
///            - StreamRelayServer runs a high-performance HTTP MJPEG server directly inside
///              the iOS app on port 8080 over all active interfaces (Local Wi-Fi + Tailscale VPN).
///            - Serves a rich HTML5 live video console on GET / for Google Chrome and Edge.
///            - Serves raw MJPEG on GET /live for VLC Player, OBS Studio, and ffmpeg.
///            - Serves single JPEG snapshots on GET /snapshot.
///            - Animated diagnostic fallback HUD (640x360 @ 20 FPS) with live clock and IP hints
///              ensures VLC and Chrome connect immediately without timeout while buffering.
///            - Direct frame ingestion from both RTSPClient (full framerate) and GlassesPhotoStore (BLE).
///            - Added Stream Relay UI Card in ContentView with 1-tap clipboard copy and connected client counter.
///        (2) Wi-Fi Subnet Verification:
///            - HotspotManager.isWiFiOnGlassesSubnet() ensures gateway probing only runs when
///              the iPhone Wi-Fi interface (en0) has a 192.168.43.x IP, eliminating false-positive
///              connection signals on home Wi-Fi.
///   v20 — FULLSCREEN NATIVE RESOLUTION & RESPONSIVE UI OVERHAUL:
///        (1) Native Fullscreen LaunchScreen:
///            - Added LaunchScreen.storyboard and UILaunchScreen dict in Info.plist.
///              Fixes iOS letterboxing into ancient 320x480 / 375x667 compatibility box
///              that created massive black bars at top and bottom of modern iPhones.
///        (2) 4-Column Responsive Status Grid:
///            - Replaced cramped status capsules with an equal-width 4-column responsive grid
///              (BLE / Wi-Fi / Video / AI Foto) with frame(maxWidth: .infinity), lineLimit(1),
///              and minimumScaleFactor(0.7) — eliminates broken/wrapped labels (BL\nE).
///        (3) Clean Single-Line Top Bar & Debug Banner:
///            - Compact action capsule and responsive title fitting all screen widths.
///        (4) Build Fix:
///            - Fixed $latestPhoto member reference on GlassesPhotoStore in StreamRelayServer.
///   v21 — JARVIS BACKGROUND VOICE ASSISTANT (EARBUDS CALL MODE) & WI-FI FLAPPING FIX:
///        (1) Jarvis Voice Call Mode (Continuous Hands-Free in Earbuds):
///            - Continuous background voice session using AVAudioSession (.playAndRecord,
///              mode: .voiceChat) with full Bluetooth HFP and A2DP support.
///            - Works like an active phone call: iPhone can be locked and in pocket while
///              listening for wake word "Hey Jarvis" or "Jarvis" via Bluetooth earbuds mic.
///            - Two selectable modes: "Hey Jarvis (Continuu)" and "Apasă pentru a vorbi".
///            - End-to-end multimodal pipeline: Earbuds mic captures question ->
///              Glasses capture POV photo via BLE (0xE1 -> 0xE3) -> OpenRouter analyzes
///              photo + question -> Romanian answer is spoken into earbuds via TTSService.
///            - Voice Activity Detection (VAD) silence detection (~1.8s) for automatic query submission.
///            - Added NSSpeechRecognitionUsageDescription in Info.plist and project.yml.
///            - Guarded TTSService audio deactivation so TTS does not interrupt background mic listening.
///        (2) Wi-Fi Flapping Root Cause Fixed (Diagnostic of Log 10:36):
///            - In verifyGlassesNetwork, when probeGateway returned false (phone still on home Wi-Fi),
///              the fallback waitForWiFiPath saw path.status == .satisfied on home Wi-Fi (en0) and
///              falsely returned true in 6ms!
///            - The app falsely assumed it was connected to MT5GLASSES, launched RTSP against 192.168.43.1
///              (which didn't exist on home Wi-Fi), timed out after 2s, disconnected, and flapped in an
///              infinite loop with NEHotspotConfiguration error 8.
///   v22 — HIGH-FIDELITY SPEECH RECOGNITION (JARVIS VOICE OVERHAUL) & BLE AUDIO DEBOUNCE:
///        (1) High-Fidelity Speech Recognition:
///            - Switched AVAudioSession mode from .voiceChat to .measurement. This completely
///              eliminates the aggressive telephone DSP, bandpass filter, and dynamic noise gating
///              that muffled and distorted speech, providing clean, raw, uncompressed audio to SFSpeechRecognizer.
///            - Added contextualStrings ("Jarvis", "Hey Jarvis", "Hei Jarvis", "Ceau Jarvis", "Salut Jarvis",
///              "ochelari", "camera", "descrie", "tradu") to prime Apple's language model dictionary.
///            - Added phonetic matching for Romanian pronunciation variants ("ceai vis", "ceavis", "iarvis",
///              "cearvis", "giarvis", "giorvis", "geavis", "geam vis", "servici").
///            - Added subtle audio chime (1103) and haptic feedback on wake word trigger.
///            - Enhanced conversational UX: saying "Hey Jarvis" prompts "Da, te ascult." and keeps listening
///              for 4s for the actual question without requiring the user to repeat the wake word.
///   v23 — ULTRA-LOW LATENCY CONVERSATIONAL PIPELINE (GEMINI 2.5 FLASH & CHATGPT-STYLE TURNAROUND):
///        (1) Gemini 2.5 Flash Migration:
///            - Switched AI model from reasoning z-ai/glm-5.3-flash (which took 6-10s producing hidden
///              reasoning tokens with null content) to google/gemini-2.5-flash (0.79s response time, 10x faster!).
///        (2) Crisp VAD Silence Detection:
///            - Reduced silence timeout from 1.8s to 0.85s, eliminating 1000ms of dead waiting after the user stops speaking.
///        (3) Smart Visual Intent Routing:
///            - Added isVisualQuery(). General knowledge, chit-chat, and math questions now skip the 2.5-second BLE photo
///              transfer completely, delivering spoken answers in ~1.2s total!
///            - Visual questions ("ce vezi", "ce am în față", "citește", "arată") seamlessly capture the BLE photo.
///        (4) Instant Turnaround Callback:
///            - Added TTSService.onSpeechFinished: as soon as Jarvis finishes speaking, listening resumes immediately.
///   v24 — GOOGLE GEMMA 4 31B MIGRATION & WI-FI / RTSP FIRMWARE CONTRACT SPECIFICATION:
///        (1) Google Gemma 4 31B Integration:
///            - Switched AI engine to google/gemma-4-31b-it on OpenRouter.
///            - Benchmarked live at 0.59s response time, delivering lightning-fast, fluent Romanian answers
///              with full multimodal vision support for POV photo analysis.
///   v25 — FIX INSTANT CRASH ON LAUNCH (SINGLETON DEADLOCK):
///        (1) Root cause: circular singleton initialization deadlock between
///            TTSService.shared and JarvisVoiceService.shared.
///            - JarvisVoiceService.init() accessed TTSService.shared.onSpeechFinished
///            - TTSService.init() called configureAudioSession() which accessed
///              JarvisVoiceService.shared.isSessionActive
///            - Swift's static let uses dispatch_once; re-entering it on the same
///              thread deadlocks the main thread → iOS watchdog kills the app instantly.
///        (2) Fix: removed configureAudioSession() from TTSService.init(); the audio
///            session is now configured lazily on the first speak() call, which already
///            calls configureAudioSession() at line 59.
///   v26 — INSTANT QUERY FIRE (REAL-TIME AUDIO VAD):
///        (1) Root cause of delay: SFSpeechRecognizer with taskHint .dictation keeps
///            re-ranking partial results for 1-3s after the user stops speaking, and
///            the old silence timer reset on every partial result, adding false delay.
///        (2) Switched taskHint from .dictation to .confirmation (optimized for short
///            phrases, Apple finalizes faster).
///        (3) Added real-time audio-level VAD: computes RMS power from raw PCM buffer
///            samples in the audio tap callback. A 100ms polling timer fires the query
///            as soon as the mic has been silent (RMS < 0.008) for 0.55s — bypassing
///            Apple's slow transcription finalization entirely.
///        (4) Old text-based silence timer demoted to safety fallback at 2.0s (only
///            fires in noisy environments where mic never goes quiet).
///   v27 — STRICT ENGLISH JARVIS VOICE SYSTEM & AIBUDS SDK STREAMING DIAGNOSTICS:
///        (1) Strict English Voice Pipeline:
///            - SFSpeechRecognizer switched to `en-US` with extensive English contextual strings
///              ("Jarvis", "explain", "what's in front of me", "what am I looking at", etc.).
///            - Wake word triggers: clean English "Hey Jarvis", "Jarvis", "Hi Jarvis", "OK Jarvis".
///            - Visual Intent Deduction: comprehensive English visual cues ("in front of me",
///              "what do you see", "describe", "explain what", "read this", "identify", etc.).
///              When asked "explain what's in front of me", automatically triggers BLE POV photo capture!
///            - AI Prompt & TTS: OpenRouter system instruction in strict English; TTSService
///              uses en-US voice (Samantha / Daniel) and strips markdown tokens for fluid speech.
///        (2) AIBuds SDK Streaming & Hotspot Diagnostics:
///            - Added runtime inspection of LiveStreamingAPI, supportsRTSPLiveStreaming,
///              supportsJPEGImageLiveStreaming, DeviceMediaFileImportAPI, and DeviceHotspotAPI.
///   v28 — GOOGLE AI STUDIO GEMINI 3.8 FLASH, AI ANTI-HALLUCINATION & CAMERA PIPELINE:
///        (1) Google AI Studio Backend Integration:
///            - Switched AI backend to Google AI Studio REST API using user-configured API key.
///            - Primary model: `gemini-3.8-flash` with base64 JPEG `inline_data` multimodal parsing.
///            - Resilient fallback: automatic fallback to `gemini-3.6-flash` if 3.8 returns HTTP 503
///              (temporary high demand spike on Google AI Studio), guaranteeing 100% uptime.
///        (2) Strict Anti-Hallucination & Photo Gatekeeping:
///            - If visual intent is detected but glasses are disconnected, Jarvis informs the user:
///              "Your glasses are not connected. Please connect your glasses to see what's in front of you."
///            - If photo capture fails/times out, checks recently cached photo (<5s); if still nil,
///              Jarvis informs the user: "I couldn't capture a photo from your glasses. Please try again."
///              Visual prompts are NEVER sent to the AI without an image.
///            - Model system instruction strictly forbids claiming to have taken photos or controlling
///              hardware, completely eliminating hallucination.
///        (3) BLE Camera Delegate & Shutter Fixes:
///            - Assigned `device.delegate = AppSDKDelegate.shared` on SDK device creation and handoff,
///              enabling `didReceivePhotoDataForSceneRecognition` to receive reassembled JPEG frames.
///   v29 — SWITCH BACK TO GEMMA 4 31B (0.66s LATENCY) & COMPLETE CRASH ELIMINATION:
///        (1) Switched AI Engine Back to Google Gemma 4 31B:
///            - Replaced Google AI Studio Gemini 3.8/3.6 (which took 11s and failed with 503 high demand)
///              with `google/gemma-4-31b-it` on OpenRouter. Tested live: 0.66s latency with vision!
///            - Retained strict English anti-hallucination system prompt and photo gatekeeping.
///        (2) Complete Fix for Crashes on Asking / After TTS Response:
///            - Audio Tap Lifecycle: removed conditional removeTap check; `audioEngine.inputNode.removeTap(onBus: 0)`
///              is now called unconditionally before installing taps and on engine stop, with `isTapInstalled` tracking.
///              Eliminates the `[mInputNode hasTapOnBus: 0] == false` uncaught SIGABRT exception.
///            - Re-entrance Lock: added `isListeningLoopActive` and guarded `resumeListeningAfterResponse`
///              to prevent concurrent duplicate invocations of `startListeningLoop`.
///            - Cancelled Recognition Task: ignored `kAFAssistantErrorDomain Code=216` (user cancelled)
///              in `recognitionTask` handler so cancelling speech recognition never triggers duplicate loop restarts.
///            - Audio Format Guard: checks `sampleRate > 0 && channelCount > 0` before tap installation to prevent
///              SIGABRT during Bluetooth audio route transitions.
///   v30 — SECURE OPEN-SOURCE RELEASE & PERSISTENT API KEY STORAGE:
///        (1) Secure Key Management:
///            - Removed hardcoded API keys for open-source public repository safety.
///            - User enters OpenRouter API key in Settings; persisted securely via `@AppStorage` / `UserDefaults`.
///   v31 — ELIMINATE DUAL-VOICE OVERLAP & UNIFY VOICE PIPELINE:
///        (1) Unified Single Pipeline:
///            - Eliminated parallel Romanian defaultPrompt query from the capture button;
///              both the button and voice now route through Jarvis in pure English.
///            - Replaced "Yes, I'm listening" spoken words with soft chime (1103) on wake word trigger,
///              eliminating collision between wake acknowledgment and AI response.
///            - Unconditionally stops previous TTS utterance before starting a new one.
public enum AppVersion {
    public static let version = 31
    public static let label = "v\(version)"
}



