import SwiftUI
import UIKit

// MARK: - Haptic Feedback Helper

enum HapticFeedback {
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - Pressable Button Style
// Scales the button down and dims it slightly while pressed, and fires a
// light haptic so the user always knows the tap registered.

struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1.0)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { pressed in
                if pressed {
                    HapticFeedback.light()
                }
            }
    }
}

struct Message: Identifiable {
    let id = UUID()
    let isUser: Bool
    let text: String
    /// Optional photo attached to the message (BLE snapshot or RTSP frame),
    /// rendered inside the bubble so the user sees exactly what the AI saw.
    var image: UIImage?

    init(isUser: Bool, text: String, image: UIImage? = nil) {
        self.isUser = isUser
        self.text = text
        self.image = image
    }
}

struct FullScreenImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct FullScreenImageViewer: View {
    let image: UIImage
    let onDismiss: () -> Void
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { val in scale = max(1.0, val) }
                        .onEnded { _ in withAnimation { scale = 1.0 } }
                )

            VStack {
                HStack {
                    Spacer()
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
    }
}

struct ContentView: View {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var hotspotManager = HotspotManager.shared
    @StateObject private var ttsService = TTSService.shared
    @StateObject private var rtspClient = RTSPClient.shared
    @StateObject private var relayServer = StreamRelayServer.shared
    @StateObject private var jarvisService = JarvisVoiceService.shared

    @State private var copiedRelayURL: Bool = false

    @State private var messages: [Message] = []
    @State private var promptText: String = ""
    @State private var isProcessing: Bool = false
    @AppStorage("openRouterApiKey") private var apiKey: String = ""
    @State private var showingSettings: Bool = false
    @State private var showingDebugLog: Bool = false
    @State private var showingDevicePicker: Bool = false
    @State private var showingManualWiFi: Bool = false
    @State private var showingTutorial: Bool = false
    @State private var isLivePreviewFullscreen: Bool = false
    @State private var selectedFullscreenImage: UIImage? = nil

    // Sheets presented from INSIDE the settings sheet: while a sheet is up,
    // the outer view cannot present another one, so the settings sheet owns
    // its own presentation states.
    @State private var showingDevicePickerInSettings: Bool = false
    @State private var showingManualWiFiInSettings: Bool = false
    @State private var showingTutorialInSettings: Bool = false

    /// Phase 1: the main screen is voice/vision-first — the text input is
    /// hidden by default and can be re-enabled here for debugging. Persisted
    /// in UserDefaults so the choice survives app restarts.
    @AppStorage("showTextInputEnabled") private var showTextInputEnabled: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                // Fullscreen gradient background that extends under the
                // safe areas on every device size.
                LinearGradient(
                    colors: [
                        Color(red: 0.04, green: 0.05, blue: 0.09),
                        Color(red: 0.09, green: 0.11, blue: 0.17),
                        Color(red: 0.03, green: 0.04, blue: 0.07)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                if isLivePreviewFullscreen, let frame = rtspClient.previewFrame {
                    fullscreenLiveView(frame)
                } else {
                    VStack(spacing: 12) {
                        customTopBarView

                        statusHeaderView

                        debugBannerView

                        jarvisCallCardView

                        streamRelayCardView

                        livePreviewView

                        chatListView
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        bottomControlsView
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showingSettings) {
                settingsSheet
            }
            .sheet(isPresented: $showingDebugLog) {
                DebugLogView()
            }
            .sheet(isPresented: $showingDevicePicker) {
                DevicePickerView()
            }
            .sheet(isPresented: $showingManualWiFi) {
                ManualWiFiView()
            }
            .sheet(isPresented: $showingTutorial) {
                ConnectionTutorialView()
            }
            .fullScreenCover(item: Binding<FullScreenImageItem?>(
                get: { selectedFullscreenImage.map { FullScreenImageItem(image: $0) } },
                set: { selectedFullscreenImage = $0?.image }
            )) { item in
                FullScreenImageViewer(image: item.image) {
                    selectedFullscreenImage = nil
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .onAppear {
            if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                OpenRouterService.shared.setApiKey(apiKey)
            }
            jarvisService.onMessageReceived = { isUser, text, image in
                self.messages.append(Message(isUser: isUser, text: text, image: image))
            }
            // If the hotspot configuration survived an app restart, resume
            // the stream immediately; RTSPClient retries until the glasses
            // answer.
            if hotspotManager.isConnectedToWiFi {
                rtspClient.start()
            }
        }
        .onChange(of: hotspotManager.isConnectedToWiFi) { connected in
            if connected {
                rtspClient.start()
            } else {
                rtspClient.stop()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Custom Fullscreen Top Bar

    private var customTopBarView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.cyan.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.cyan)
                }

                Text("MT5 Smart Glasses")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 6)

            HStack(spacing: 2) {
                topBarIconButton(icon: "questionmark.circle.fill", action: { showingTutorial = true })
                topBarIconButton(icon: "doc.text.magnifyingglass", action: { showingDebugLog = true })
                topBarIconButton(icon: "gearshape.fill", action: { showingSettings = true })
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func topBarIconButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.cyan)
                .padding(8)
        }
        .buttonStyle(PressableButtonStyle(scale: 0.92))
    }

    // MARK: - Fullscreen Live RTSP View

    private func fullscreenLiveView(_ frame: UIImage) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            Image(uiImage: frame)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text("LIVE STREAM • \(rtspClient.framesDecoded) CADRE")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.6)))

                Spacer()

                Button(action: { withAnimation { isLivePreviewFullscreen = false } }) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 16, weight: .bold))
                        .padding(10)
                        .background(Circle().fill(Color.black.opacity(0.65)))
                        .foregroundColor(.white)
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.top, 48)
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Status Header (4-Column Symmetrical Responsive Grid)

    private var statusHeaderView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                statusGridItem(
                    title: "BLE",
                    icon: "antenna.radiowaves.left.and.right",
                    isOk: bleManager.isDeviceConnected,
                    activeColor: .green
                )

                statusGridItem(
                    title: "Wi-Fi",
                    icon: "wifi",
                    isOk: hotspotManager.isConnectedToWiFi,
                    activeColor: .cyan
                )

                statusGridItem(
                    title: "VIDEO",
                    icon: "camera.fill",
                    isOk: rtspClient.isStreaming,
                    activeColor: .blue
                )

                statusGridItem(
                    title: "AI FOTO",
                    icon: "camera.on.rectangle.fill",
                    isOk: bleManager.canRequestAISnapshot,
                    activeColor: .purple
                )
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(bleManager.isDeviceConnected ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)

                Text(bleManager.statusMessage)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.gray)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if bleManager.batteryLevel > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "battery.75")
                            .font(.system(size: 11))
                        Text("\(bleManager.batteryLevel)%")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                }

                if ttsService.isSpeaking {
                    Image(systemName: "waveform")
                        .foregroundColor(.emeraldGreen)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func statusGridItem(title: String, icon: String, isOk: Bool, activeColor: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isOk ? activeColor : Color.gray.opacity(0.4))
                .frame(width: 5, height: 5)
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(isOk ? activeColor : .gray)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill((isOk ? activeColor : Color.gray).opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke((isOk ? activeColor : Color.clear).opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Debug Banner

    private var debugBannerView: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Circle().fill(bleManager.isSDKInitialized ? Color.green : Color.red).frame(width: 6, height: 6)
                Text(bleManager.isSDKInitialized ? "SDK Activ" : "SDK Oprit")
                    .foregroundColor(bleManager.isSDKInitialized ? .green : .red)
            }

            Text("•")
                .foregroundColor(.gray.opacity(0.4))

            HStack(spacing: 4) {
                Circle().fill(bleManager.isDeviceConnected ? Color.green : Color.red).frame(width: 6, height: 6)
                Text(bleManager.isDeviceConnected ? "Conectat" : "Deconectat")
                    .foregroundColor(bleManager.isDeviceConnected ? .green : .red)
            }

            Spacer(minLength: 4)

            Text(AppVersion.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.cyan.opacity(0.15))
                )
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                )
        )
    }

    // MARK: - Jarvis Voice Call Card (Earbuds / Hands-Free)

    private var jarvisCallCardView: some View {
        VStack(spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: jarvisService.isSessionActive ? "phone.fill" : "phone")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(jarvisService.isSessionActive ? .green : .cyan)
                    Text("Jarvis Voice Call (Earbuds)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(jarvisService.isSessionActive ? Color.green : Color.gray)
                        .frame(width: 6, height: 6)
                    Text(jarvisService.voiceState.rawValue)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(jarvisService.isSessionActive ? .green : .gray)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            if jarvisService.isSessionActive {
                if !jarvisService.liveTranscript.isEmpty {
                    Text("\"\(jarvisService.liveTranscript)\"")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(.cyan)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    Button(action: { jarvisService.stopVoiceSession() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "phone.down.fill")
                            Text("END CALL")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.8)))
                    }
                    .buttonStyle(PressableButtonStyle())

                    Picker("Mode", selection: $jarvisService.currentMode) {
                        ForEach(JarvisVoiceService.Mode.allCases) { mode in
                            Text(mode == .wakeWord ? "Hey Jarvis" : "Manual").tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .frame(width: 150)
                }
            } else {
                HStack {
                    Text("Hands-free in background. Say \"Hey Jarvis, explain what's in front of me\".")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.gray)
                        .lineLimit(2)

                    Spacer(minLength: 8)

                    Button(action: { jarvisService.startVoiceSession() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "phone.fill")
                            Text("START CALL")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.green))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(jarvisService.isSessionActive ? Color.green.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: - Stream Relay Card (PC Streaming Antenna via Tailscale / LAN)

    private var streamRelayCardView: some View {
        VStack(spacing: 6) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan)
                    Text("Releu PC (Tailscale / LAN)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                Spacer()

                if relayServer.activeClientsCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(relayServer.activeClientsCount) PC Conectat")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.green)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
                } else {
                    HStack(spacing: 4) {
                        Circle().fill(relayServer.isRunning ? Color.cyan : Color.gray).frame(width: 6, height: 6)
                        Text(relayServer.isRunning ? "Server Activ" : "Oprit")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundColor(relayServer.isRunning ? .cyan : .gray)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
            }

            HStack(spacing: 8) {
                Text(relayServer.primaryURL.isEmpty ? "Căutare IP-uri..." : relayServer.primaryURL)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(relayServer.primaryURL.isEmpty ? .gray : .cyan)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: {
                    UIPasteboard.general.string = relayServer.primaryURL
                    HapticFeedback.success()
                    withAnimation { copiedRelayURL = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation { copiedRelayURL = false }
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copiedRelayURL ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .bold))
                        Text(copiedRelayURL ? "Copiat!" : "Copiază")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(copiedRelayURL ? .green : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(copiedRelayURL ? Color.green.opacity(0.25) : Color.cyan.opacity(0.2))
                    )
                }
                .buttonStyle(PressableButtonStyle())
            }

            Text("Deschide linkul în Chrome (browser) sau în VLC Player pe calculator.")
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.gray.opacity(0.8))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.cyan.opacity(0.18), lineWidth: 1)
                )
        )
    }

    // MARK: - Live Preview (RTSP frame from the glasses)

    /// Compact live thumbnail of the latest decoded RTSP frame. Appears only
    /// once frames actually arrive, giving immediate visual confirmation that
    /// the image pipeline works end-to-end.
    @ViewBuilder
    private var livePreviewView: some View {
        if let frame = rtspClient.previewFrame {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                HStack(spacing: 6) {
                    Text("LIVE")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.red.opacity(0.75)))
                        .foregroundColor(.white)
                    Text("\(rtspClient.framesDecoded) cadre")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .foregroundColor(.white)
                    Spacer()

                    Button(action: { withAnimation { isLivePreviewFullscreen = true } }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 10, weight: .bold))
                            Text("FULLSCREEN")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.85)))
                        .foregroundColor(.black)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(8)
            }
        }
    }

    // MARK: - Chat List

    private var chatListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if messages.isEmpty {
                        emptyStateView
                    } else {
                        ForEach(messages) { msg in
                            chatBubble(msg)
                                .id(msg.id)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _ in
                if let lastId = messages.last?.id {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 10)

            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "eyeglasses")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(.cyan)
            }

            Text("Asistent Inteligent MT5")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text("Apasă butonul de mai jos: ochelarii capturează ce vezi, AI-ul analizează imaginea și răspunsul îți este citit în difuzoare.")
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
                .padding(.horizontal, 24)

            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func chatBubble(_ msg: Message) -> some View {
        HStack(alignment: .bottom) {
            if msg.isUser { Spacer(minLength: 48) }
            VStack(alignment: msg.isUser ? .trailing : .leading, spacing: 6) {
                if let image = msg.image {
                    Button(action: { selectedFullscreenImage = image }) {
                        ZStack(alignment: .bottomTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: 280, maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )

                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 10, weight: .bold))
                                Text("FULLSCREEN")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.black.opacity(0.65)))
                            .padding(8)
                        }
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                Text(msg.text)
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Group {
                            if msg.isUser {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(LinearGradient(
                                        colors: [Color.cyan, Color.blue.opacity(0.85)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ))
                            } else {
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color.white.opacity(0.08))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18)
                                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            }
                        }
                    )
            }
            if !msg.isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: - Bottom Controls

    /// Voice/vision-first controls: one large capture trigger. The text field
    /// is a debug-only affordance (Settings -> Interfață).
    private var bottomControlsView: some View {
        VStack(spacing: 12) {
            if showTextInputEnabled {
                HStack(spacing: 10) {
                    TextField("Scrie o întrebare...", text: $promptText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.08))
                        )
                        .foregroundColor(.white)

                    Button(action: { sendTextQuery(promptText) }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(promptText.isEmpty ? .gray : .cyan)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(promptText.isEmpty || isProcessing)
                }
            }

            Button(action: askAIAction) {
                HStack(spacing: 8) {
                    if isProcessing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "sparkles")
                        Text("ÎNTREABĂ ASISTENTUL AI")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    Group {
                        if isProcessing {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.gray.opacity(0.4))
                        } else {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(LinearGradient(
                                    colors: [Color.cyan, Color(red: 0.0, green: 0.72, blue: 0.85)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ))
                        }
                    }
                )
                .foregroundColor(.black)
            }
            .buttonStyle(PressableButtonStyle(scale: 0.97))
            .disabled(isProcessing)
        }
    }

    // MARK: - Settings Sheet

    private var settingsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("OpenRouter API (Google Gemma 4 31B)"),
                        footer: Text(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Introduceți cheia API OpenRouter (sk-or-v1-...) pentru a activa asistentul Jarvis." : "Cheia API este salvată în siguranță pe dispozitiv.")) {
                    SecureField("OpenRouter API Key (sk-or-v1-...)", text: $apiKey)
                        .onChange(of: apiKey) { newValue in
                            OpenRouterService.shared.setApiKey(newValue)
                        }
                }

                Section(header: Text("Interfață"),
                        footer: Text("Ecranul principal este proiectat hands-free: un singur buton de captură, răspuns vocal. Căsuța de text rămâne disponibilă doar pentru depanare.")) {
                    Toggle("Afișează căsuța de text (debug)", isOn: $showTextInputEnabled)
                }

                Section(header: Text("Conectare BLE"),
                        footer: Text("Conectarea rulează integral prin SDK-ul AIBuds (fluxul oficial: scanare SDK → dispozitiv stocabil → conectare SDK → deviceDidReady → captură foto BLE). Dacă aplicația nu găsește ochelarii automat, dezactivați conectarea automată și alegeți dispozitivul din lista de scanare. „Bluetooth clasic\" activează profilul SPP la conectare (experiment).")) {
                    Toggle("Conectare automată", isOn: $bleManager.isAutoConnectEnabled)
                    Toggle("Bluetooth clasic la conectare (SPP)", isOn: $bleManager.isClassicBTEnabled)
                    Button("Selectare manuală ochelari...") {
                        showingDevicePickerInSettings = true
                    }
                    .buttonStyle(PressableButtonStyle())
                    Button("Reîncercați scanarea") {
                        bleManager.startConnectionFlow()
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                Section(header: Text("Conectare manuală Wi-Fi"),
                        footer: Text("Aplicația cere hotspot-ul sub numele fix MT5GLASSES (parolă implicită 12345678). Folosiți această opțiune dacă ochelarii difuzează alt nume sau nu pornesc hotspot-ul prin BLE.")) {
                    Button("Introducere SSID și parolă...") {
                        showingManualWiFiInSettings = true
                    }
                    .buttonStyle(PressableButtonStyle())
                    Text(hotspotManager.connectionStatus)
                        .font(.footnote)
                        .foregroundColor(hotspotManager.isConnectedToWiFi ? .green : .gray)
                }

                Section(header: Text("Control Ochelari")) {
                    Button("Scanare BLE") {
                        bleManager.startScanning()
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button("Activare Hotspot AP") {
                        bleManager.requestHotspotAP()
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button("Pornire Stream RTSP") {
                        bleManager.startRTSPStream()
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button("Pornire Microfon") {
                        bleManager.startMicrophoneRecording()
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button("Activare Bluetooth Audio (Difuzoare)") {
                        bleManager.triggerClassicBTAudio()
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                Section(header: Text("Releu Video PC (Tailscale / LAN)"),
                        footer: Text("Transmite fluxul camerei ochelarilor direct către PC peste Tailscale sau rețeaua Wi-Fi de acasă. Deschide linkul în Google Chrome sau VLC Player.")) {
                    HStack {
                        Text("Stare Server")
                        Spacer()
                        Text(relayServer.isRunning ? "🟢 Activ (Port 8080)" : "🔴 Oprit")
                            .foregroundColor(relayServer.isRunning ? .green : .red)
                    }

                    if !relayServer.tailscaleURLs.isEmpty {
                        ForEach(relayServer.tailscaleURLs, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Tailscale (VPN)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.cyan)
                                    Text(url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Button(action: {
                                    UIPasteboard.general.string = url
                                    HapticFeedback.success()
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                    }

                    if !relayServer.localURLs.isEmpty {
                        ForEach(relayServer.localURLs, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wi-Fi Local (Acasă)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.cyan)
                                    Text(url)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                                Spacer()
                                Button(action: {
                                    UIPasteboard.general.string = url
                                    HapticFeedback.success()
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.cyan)
                                }
                            }
                        }
                    }

                    Button("Reîmprospătează adresele de rețea") {
                        relayServer.refreshNetworkAddresses()
                        HapticFeedback.light()
                    }
                    .buttonStyle(PressableButtonStyle())
                }

                Section(header: Text("Versiune aplicație"),
                        footer: Text("Numărul de build crește la fiecare commit. Compară-l cu numărul comunicat în chat: dacă este mai mic, aplicația instalată pe telefon este învechită.")) {
                    Text("Build \(AppVersion.label)")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.cyan)
                }

                Section(header: Text("Ajutor")) {
                    Button("Tutorial conectare") {
                        showingTutorialInSettings = true
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .navigationTitle("Setări")
            .navigationBarItems(trailing: Button("Închide") { showingSettings = false })
            // Sheets presented from within the settings sheet need their own
            // presentation bindings on the sheet's content.
            .sheet(isPresented: $showingDevicePickerInSettings) {
                DevicePickerView()
            }
            .sheet(isPresented: $showingManualWiFiInSettings) {
                ManualWiFiView()
            }
            .sheet(isPresented: $showingTutorialInSettings) {
                ConnectionTutorialView()
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Actions

    /// The main AI trigger — the glasses-native loop:
    /// BLE AI snapshot (`CaptureMode.ai` via the SDK's DeviceCameraAPI) ->
    /// Base64 vision query to OpenRouter -> spoken answer through TTS.
    ///
    /// Fallback chain when the BLE capture is unavailable (no deviceDidReady):
    /// the latest decoded RTSP frame, then a text-only query — each step is
    /// announced in the chat so the user always knows which source was used.
    ///
    /// NOTE: `self` is captured strongly (no `[weak self]`) because
    /// ContentView is a STRUCT — `weak` only applies to class instances.
    /// This is safe in SwiftUI: the closure captures a value copy, and the
    /// mutated properties (`messages`, `isProcessing`) are `@State`, whose
    /// setters are nonmutating and write through to SwiftUI's storage.
    private func askAIAction() {
        HapticFeedback.medium()
        let defaultPrompt = "Descrie ce vezi în imagine și explică ce este important."
        isProcessing = true

        if bleManager.canRequestAISnapshot {
            messages.append(Message(isUser: true, text: "📸 Se capturează o imagine prin BLE..."))
            bleManager.requestAISnapshot { image, errorMessage in
                if let image = image {
                    self.messages.append(Message(isUser: true, text: "📷 [Imagine de la ochelari — BLE] \(defaultPrompt)", image: image))
                    self.sendAIQuery(prompt: defaultPrompt, image: image)
                } else {
                    self.messages.append(Message(isUser: false, text: "⚠️ Captura BLE a eșuat: \(errorMessage ?? "motiv necunoscut"). Încerc cadrul din stream-ul RTSP..."))
                    self.captureRTSPFrameAndQuery(prompt: defaultPrompt)
                }
            }
        } else {
            // Surface WHY the BLE path is unavailable instead of falling back
            // silently — otherwise the button behaves identically to the old
            // RTSP-only flow and the user cannot tell the difference.
            let reason = !bleManager.isReady ? "BLE neconectat" : "Canal BLE indisponibil"
            messages.append(Message(isUser: false, text: "ℹ️ Captura BLE indisponibilă (\(reason)). Folosesc cadrul din stream-ul RTSP, dacă există."))
            captureRTSPFrameAndQuery(prompt: defaultPrompt)
        }
    }

    /// Fallback image source: the latest decoded RTSP frame. Falls back to a
    /// text-only query when the stream is not running or has stalled.
    private func captureRTSPFrameAndQuery(prompt: String) {
        if let frame = rtspClient.captureLatestFrame() {
            messages.append(Message(isUser: true, text: "📷 [Imagine de la ochelari — RTSP] \(prompt)", image: frame))
            sendAIQuery(prompt: prompt, image: frame)
        } else {
            messages.append(Message(isUser: false, text: "⚠️ Nu s-a putut obține nicio imagine de la ochelari (nici BLE, nici RTSP). Verificați conexiunea camerei."))
            isProcessing = false
        }
    }

    /// Sends the prompt (with an optional image) to OpenRouter and surfaces
    /// the result in the chat + TTS. Resets `isProcessing` on every path.
    /// `self` is captured strongly — ContentView is a struct (see askAIAction).
    private func sendAIQuery(prompt: String, image: UIImage?) {
        OpenRouterService.shared.sendQuery(prompt: prompt, image: image) { result in
            DispatchQueue.main.async {
                self.isProcessing = false
                switch result {
                case .success(let response):
                    self.messages.append(Message(isUser: false, text: response))
                    self.ttsService.speak(text: response)
                    HapticFeedback.success()
                case .failure(let error):
                    let errorMsg = "Eroare: \(error.localizedDescription)"
                    self.messages.append(Message(isUser: false, text: errorMsg))
                    HapticFeedback.error()
                }
            }
        }
    }

    private func sendTextQuery(_ text: String) {
        guard !text.isEmpty else { return }
        messages.append(Message(isUser: true, text: text))
        promptText = ""
        isProcessing = true
        sendAIQuery(prompt: text, image: nil)
    }
}

extension Color {
    static let emeraldGreen = Color(red: 0.1, green: 0.8, blue: 0.4)
}

// MARK: - Manual BLE Device Picker
// Fallback for when automatic candidate validation cannot recognize the
// glasses: every device found by the SDK scan is listed here and the user
// connects by tapping a row (through the same official SDK path).

struct DevicePickerView: View {
    @StateObject private var bleManager = BLEManager.shared
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Conectare automată la candidați", isOn: $bleManager.isAutoConnectEnabled)
                    Text(bleManager.statusMessage)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.gray)
                }
                .padding()

                Divider()

                if bleManager.discoveredPeripherals.isEmpty {
                    Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Se scanează... Apropiați-vă de ochelari.")
                            .font(.system(size: 13))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                } else {
                    List(bleManager.discoveredPeripherals) { device in
                        Button {
                            HapticFeedback.light()
                            bleManager.connect(to: device)
                            presentationMode.wrappedValue.dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(.white)
                                    Text(device.id.uuidString)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.gray)
                                }
                                Spacer()
                                Text("\(device.rssi) dBm")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(device.rssi > -70 ? .green : (device.rssi > -85 ? .orange : .red))
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                    .listStyle(PlainListStyle())
                }
            }
            .navigationTitle("Selectați ochelarii")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Închide") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Reîncarcă") {
                        bleManager.startConnectionFlow()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Make sure a scan is running so the picker fills up, without
            // disturbing an in-flight connection.
            if bleManager.state == .idle {
                bleManager.startScanning()
            }
        }
    }
}

// MARK: - Manual Wi-Fi Join
// Fallback for when the requested hotspot name never comes up (or the glasses
// broadcast a different name): the user types the glasses' hotspot credentials
// and the app joins the network through NEHotspotConfigurationManager.

struct ManualWiFiView: View {
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var hotspotManager = HotspotManager.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var ssid: String = ""
    @State private var password: String = "12345678"

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Hotspot ochelari"),
                        footer: Text("Aplicația cere hotspot-ul sub numele fix MT5GLASSES; parola implicită este 12345678. Dacă ochelarii difuzează alt nume, introduceți-l aici. Dacă telefonul este deja conectat la hotspot, apăsați oricum Conectare — aplicația va verifica conectivitatea în loc să eșueze.")) {
                    TextField("SSID (ex. MT5GLASSES)", text: $ssid)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    SecureField("Parolă", text: $password)
                }

                Section {
                    Button("Conectare") {
                        HapticFeedback.medium()
                        bleManager.connectWiFiManually(ssid: ssid, password: password)
                        presentationMode.wrappedValue.dismiss()
                    }
                    .disabled(ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hotspotManager.isConnecting)

                    if hotspotManager.isConnecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Se conectează...")
                                .font(.footnote)
                                .foregroundColor(.gray)
                        }
                    }
                }

                Section(header: Text("Stare")) {
                    Text(hotspotManager.connectionStatus)
                        .font(.footnote)
                        .foregroundColor(hotspotManager.isConnectedToWiFi ? .green : .gray)
                }
            }
            .navigationTitle("Wi-Fi manual")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Închide") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Connection Tutorial
// Step-by-step guide built on the public integration reference: the portable
// workflow (initialize -> ready callback -> validate -> serialize -> react to
// callbacks -> stop through documented APIs) applied to this app's chain
// BLE -> hotspot AP -> Wi-Fi -> RTSP -> AI.

struct ConnectionTutorialView: View {
    @Environment(\.presentationMode) private var presentationMode
    @StateObject private var bleManager = BLEManager.shared
    @StateObject private var hotspotManager = HotspotManager.shared
    @StateObject private var rtspClient = RTSPClient.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    liveStatusCard
                    stepsCard
                    troubleshootingCard
                    docsCard
                }
                .padding()
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Tutorial conectare")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button("Închide") {
                presentationMode.wrappedValue.dismiss()
            })
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Live status

    private var liveStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stare curentă")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            tutorialRow(index: 1, title: "BLE", detail: bleManager.isDeviceConnected ? "Conectat" : "Neconectat", ok: bleManager.isDeviceConnected)
            tutorialRow(index: 2, title: "Wi-Fi", detail: hotspotManager.connectionStatus, ok: hotspotManager.isConnectedToWiFi)
            tutorialRow(index: 3, title: "RTSP", detail: rtspClient.statusMessage, ok: rtspClient.isStreaming)
            tutorialRow(index: 4, title: "SNAP", detail: bleManager.canRequestAISnapshot ? "Captură BLE activă" : "Cade pe RTSP", ok: bleManager.canRequestAISnapshot)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: Steps

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pașii conexiunii")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            stepRow(number: "1",
                    title: "Porniți ochelarii și țineți-i lângă telefon",
                    detail: "Bluetooth-ul telefonului trebuie activat. Aplicația pornește scanarea prin SDK la pornire.")
            stepRow(number: "2",
                    title: "Scanarea și conectarea prin SDK (fluxul oficial)",
                    detail: "SDK-ul AIBuds scanează cu propriul său manager Bluetooth, găsește ochelarii, îi convertește în dispozitiv stocabil și efectuează el însuși conectarea și handshake-ul propriu. Când handshake-ul se termină, SDK-ul apelează deviceDidReady — iar captura foto prin BLE devine activă (badge-ul SNAP devine verde).")
            stepRow(number: "3",
                    title: "Activarea automată a hotspot-ului",
                    detail: "La ready, aplicația cere hotspot-ul cu un nume fix ales de aplicație (MT5GLASSES, parolă implicită 12345678) și se conectează la el. Dacă ochelarii raportează alt nume, aplicația îl folosește pe acela.")
            stepRow(number: "4",
                    title: "Pornirea stream-ului RTSP",
                    detail: "După Wi-Fi, aplicația trimite comanda RTSP (0x12) și începe decodarea fluxului rtsp://192.168.43.1:554/live. Badge-ul CAM devine verde și apare previzualizarea LIVE.")
            stepRow(number: "5",
                    title: "Întrebați asistentul AI",
                    detail: "Butonul principal capturează o imagine prin BLE (fără Wi-Fi). Imaginea pleacă către AI, iar răspunsul este afișat în chat și citit cu voce tare. Fluxul RTSP este doar o sursă de imagine de rezervă.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: Troubleshooting

    private var troubleshootingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dacă ceva nu funcționează")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            stepRow(number: "BLE",
                    title: "Ochelarii nu sunt găsiți automat",
                    detail: "Deschideți „Ochelari BLE\" (butonul de pe ecran sau din Setări). Lista arată TOATE dispozitivele găsite de scanarea SDK; alegeți ochelarii din listă (verificați numele/semnalul). Puteți dezactiva „Conectare automată\" ca aplicația să nu mai conecteze singură candidații.")
            stepRow(number: "Wi-Fi",
                    title: "Telefonul nu se conectează la hotspot",
                    detail: "Aplicația cere hotspot-ul sub numele fix „MT5GLASSES\" (parolă 12345678). Dacă ochelarii difuzează alt nume, folosiți „Wi-Fi manual\" și introduceți SSID-ul real. Dacă telefonul este DEJA conectat la hotspot, apăsați oricum Conectare: aplicația verifică conectivitatea în loc să raporteze eroare.")
            stepRow(number: "RTSP",
                    title: "Stream-ul nu pornește",
                    detail: "Verificați că badge-ul Wi-Fi este verde, apoi folosiți Setări → „Pornire Stream RTSP\". Clientul RTSP reîncearcă automat câteva minute; verificați Debug Log (iconița lupa) pentru erori.")
            stepRow(number: "SNAP",
                    title: "Badge-ul SNAP rămâne gri",
                    detail: "Captura BLE necesită deviceDidReady. Urmăriți în Debug Log: „SDK connect (official flow)\", apoi „deviceDidReady\" (succes) sau „didFailToConnectDevice\" (eșec — notați codul erorii). Dacă handshake-ul SDK se blochează, restul pipeline-ului (hotspot/RTSP) funcționează în continuare pe canalul raw.")
            stepRow(number: "SDK",
                    title: "SDK Status roșu (Neinițializat)",
                    detail: "Cauza cea mai frecventă: lipsesc descrierile de utilizare Bluetooth din Info.plist (NSBluetoothAlwaysUsageDescription și NSBluetoothWhileInUseUsageDescription). Verificați iOS/project.yml și regenerați proiectul.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: Official documentation

    private var docsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Documentație oficială")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            docLink(title: "Instalare și module",
                    url: "https://docs-aibuds.github.io/docs/getting-started/installation")
            docLink(title: "Prima integrare funcțională (quickstart)",
                    url: "https://docs-aibuds.github.io/docs/getting-started/quickstart")
            docLink(title: "Live streaming (RTSP / JPEG)",
                    url: "https://docs-aibuds.github.io/docs/core/live-streaming/rtsp")
            docLink(title: "Depanare probleme comune",
                    url: "https://docs-aibuds.github.io/docs/troubleshooting/common-issues")
            docLink(title: "Referință API publică",
                    url: "https://docs-aibuds.github.io/api-reference/aibuds-sdk")

            Text("Regula de aur din referința publică: nu presupuneți starea dispozitivului după o comandă — reconciliați-o prin proprietățile și callback-urile publice. Aplicația folosește exact acest model: badge-urile de stare reflectă callback-urile, nu presupuneri.")
                .font(.system(size: 12))
                .foregroundColor(.gray)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    // MARK: Helpers

    private func tutorialRow(index: Int, title: String, detail: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text("\(index). \(title)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(ok ? .green : .gray)
                .lineLimit(1)
        }
    }

    private func stepRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(.cyan)
                .frame(minWidth: 34)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.cyan.opacity(0.15)))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func docLink(title: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                Image(systemName: "safari")
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10))
            }
            .foregroundColor(.cyan)
        }
    }
}
