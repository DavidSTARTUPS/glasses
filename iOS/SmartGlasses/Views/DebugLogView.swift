import SwiftUI
import Foundation
import UIKit

// MARK: - Debug Log Model & Logger
// These types are defined here (inside a file that IS part of the target's
// Compile Sources) because Services/DebugLogger.swift was missing from the
// Xcode target, which made the build fail with
// "cannot find 'DebugLogger' in scope" (see debug.txt).

public enum DebugLogLevel: String {
    case info    // General app / connection events
    case tx      // Outgoing ABMate command (BLE write)
    case rx      // Incoming ABMate notification (BLE read)
    case wifi    // Hotspot / Wi-Fi pipeline events
    case error   // Failures that need attention
}

public struct DebugLogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let level: DebugLogLevel
    public let message: String

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public var timeText: String {
        Self.timeFormatter.string(from: timestamp)
    }
}

/// Shared, in-memory ring buffer of debug events.
/// Populated by BLEManager and HotspotManager; displayed by the debug log UI.
public final class DebugLogger: ObservableObject {
    public static let shared = DebugLogger()

    @Published public private(set) var entries: [DebugLogEntry] = []

    private let maxEntries = 400

    private init() {}

    public func log(_ message: String, level: DebugLogLevel = .info) {
        let entry = DebugLogEntry(timestamp: Date(), level: level, message: message)
        // All mutations happen on the main queue: log volume is low and this
        // keeps @Published access race-free.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.entries.append(entry)
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    public func clear() {
        DispatchQueue.main.async { [weak self] in
            self?.entries.removeAll()
        }
    }
}

// MARK: - Debug Log View

struct DebugLogView: View {
    @StateObject private var logger = DebugLogger.shared
    @Environment(\.presentationMode) private var presentationMode

    @State private var levelFilter: DebugLogLevel?
    // Export (download) state: the log is written to a temp file and handed
    // to the iOS share sheet, which offers "Save to Files" / AirDrop / Mail.
    @State private var isShowingShareSheet: Bool = false
    @State private var shareItems: [Any] = []

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private var filteredEntries: [DebugLogEntry] {
        guard let filter = levelFilter else { return logger.entries }
        return logger.entries.filter { $0.level == filter }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                filterBar
                Divider()
                logList
            }
            .background(Color(red: 0.05, green: 0.06, blue: 0.09).ignoresSafeArea())
            .navigationTitle("Debug Log (\(logger.entries.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Închide") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { exportDebugLog() }) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundColor(.cyan)
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Descarcă jurnalul de depanare")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { logger.clear() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ActivityView(items: shareItems)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "Toate", color: .cyan, isActive: levelFilter == nil) {
                    levelFilter = nil
                }
                ForEach([DebugLogLevel.info, .tx, .rx, .wifi, .error], id: \.self) { level in
                    filterChip(title: level.label, color: level.color, isActive: levelFilter == level) {
                        levelFilter = (levelFilter == level) ? nil : level
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(title: String, color: Color, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive ? color.opacity(0.25) : Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule().stroke(isActive ? color.opacity(0.6) : Color.white.opacity(0.1), lineWidth: 1)
                )
                .foregroundColor(isActive ? color : .gray)
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: - Log List

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if filteredEntries.isEmpty {
                        emptyLogView
                    } else {
                        ForEach(filteredEntries) { entry in
                            logRow(entry)
                                .id(entry.id)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: filteredEntries.count) { _ in
                if let last = filteredEntries.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyLogView: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.gray)
            Text("Niciun eveniment înregistrat încă.")
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func logRow(_ entry: DebugLogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timeText)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(.gray)

            Text(entry.level.label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(entry.level.color)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Capsule().fill(entry.level.color.opacity(0.15)))

            Text(entry.message)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    // MARK: - Log Export (download button)

    /// Writes the ENTIRE log (ignores the on-screen filter — a complete log is
    /// what matters for debugging) to a timestamped .log file in the temp
    /// directory and presents the iOS share sheet. "Save to Files" from the
    /// sheet is the download path.
    private func exportDebugLog() {
        let text = makeLogText()
        let fileName = "smartglasses-debug-\(Self.fileTimestampFormatter.string(from: Date())).log"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(fileName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItems = [url]
        } catch {
            // The temp file could not be written — share the raw text instead.
            shareItems = [text]
        }
        isShowingShareSheet = true
    }

    private func makeLogText() -> String {
        var lines: [String] = []
        lines.append("SmartGlasses — jurnal de depanare")
        lines.append("Exportat: \(Date())")
        lines.append("Build: \(AppVersion.label)")
        lines.append("iOS: \(UIDevice.current.systemVersion)")
        lines.append("Evenimente: \(logger.entries.count)")
        lines.append(String(repeating: "-", count: 60))
        for entry in logger.entries {
            lines.append("\(entry.timeText) [\(entry.level.label)] \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Share Sheet (iOS 15 compatible; ShareLink requires iOS 16)

/// Wraps UIActivityViewController for presentation as a SwiftUI sheet.
/// Presented through .sheet it also renders correctly on iPad (page sheet),
/// no popover source view required.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - DebugLogLevel UI Helpers

extension DebugLogLevel {
    var color: Color {
        switch self {
        case .info:  return .cyan
        case .tx:    return .orange
        case .rx:    return .green
        case .wifi:  return .blue
        case .error: return .red
        }
    }

    var label: String {
        switch self {
        case .info:  return "INFO"
        case .tx:    return "TX"
        case .rx:    return "RX"
        case .wifi:  return "WIFI"
        case .error: return "ERROR"
        }
    }
}
