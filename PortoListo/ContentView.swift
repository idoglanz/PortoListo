import SwiftUI

// MARK: - Menu Bar View (Popover Content)

struct MenuBarView: View {
    @ObservedObject var monitor: PortMonitor
    @State private var showSettings = false
    @State private var showHelp = false

    private var activeStatuses: [PortStatus] { monitor.statuses.filter { $0.isActive } }
    private var availableStatuses: [PortStatus] { monitor.statuses.filter { !$0.isActive } }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().opacity(0.5)

            if let error = monitor.lastError {
                errorBanner(error)
            }

            if monitor.watchedPorts.isEmpty {
                emptyState
            } else if monitor.lastRefreshed == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {

                        if !activeStatuses.isEmpty {
                            SectionLabel(title: "ACTIVE PORTS", count: activeStatuses.count, color: .green)
                                .padding(.top, 10)
                            ForEach(activeStatuses) { PortRow(status: $0, monitor: monitor) }
                        }

                        if !availableStatuses.isEmpty {
                            SectionLabel(title: "AVAILABLE", count: availableStatuses.count, color: .secondary)
                                .padding(.top, activeStatuses.isEmpty ? 10 : 8)
                            ForEach(availableStatuses) { PortRow(status: $0, monitor: monitor) }
                        }

                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            }

            Divider().opacity(0.5)

            footer
        }
        .background(Color(NSColor.windowBackgroundColor))
        .sheet(isPresented: $showSettings) {
            SettingsView(monitor: monitor)
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
    }

    // MARK: - Header
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "network")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            Text("porto-listo")
                .font(.system(size: 13, weight: .bold, design: .rounded))

            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 12, height: 12)
                    .fixedSize()
            }

            Spacer()

            HStack(spacing: 10) {
                BarButton(icon: "arrow.clockwise", help: "Refresh now") {
                    Task { await monitor.refresh() }
                }
                BarButton(icon: "questionmark.circle", help: "About") {
                    showHelp = true
                }
                BarButton(icon: "slider.horizontal.3", help: "Configure ports") {
                    showSettings = true
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Error Banner
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .lineLimit(2)
            Spacer()
            Button {
                monitor.dismissError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Footer
    private var footer: some View {
        HStack {
            if let refreshed = monitor.lastRefreshed {
                Text("Updated \(refreshed, formatter: timeFormatter)")
                    .font(.system(size: 10))
                    .foregroundColor(Color.secondary.opacity(0.55))
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(Color.secondary.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "network.slash")
                .font(.system(size: 28, weight: .thin))
                .foregroundColor(Color.secondary.opacity(0.5))
            Text("No ports configured")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Button("Add ports ->") { showSettings = true }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundColor(.accentColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Section Label

struct SectionLabel: View {
    let title: String
    let count: Int
    let color: Color

    private var isSubdued: Bool { color == .secondary }

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.secondary)
                .tracking(1.2)

            Text("\(count)")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(isSubdued ? .secondary : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(isSubdued ? Color.secondary.opacity(0.2) : color.opacity(0.8)))
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 3)
    }
}

// MARK: - Port Row

struct PortRow: View {
    let status: PortStatus
    @ObservedObject var monitor: PortMonitor
    @State private var isHovered = false
    @State private var isEditingLabel = false
    @State private var labelDraft = ""

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                if status.isActive {
                    Circle().fill(Color.green.opacity(0.18)).frame(width: 20, height: 20)
                }
                Circle()
                    .fill(status.isActive ? Color.green : Color.secondary.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
            .frame(width: 20)

            // Info block
            VStack(alignment: .leading, spacing: 2) {
                // Port number + label
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(":\(String(status.port))")
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))

                    if isEditingLabel {
                        TextField("Label", text: $labelDraft, onCommit: saveLabel)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .frame(maxWidth: 120)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(NSColor.textBackgroundColor))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                            )
                            .onExitCommand { isEditingLabel = false }
                    } else if !status.watchedPort.label.isEmpty {
                        Text(status.watchedPort.label)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                // Process info or free
                if let info = status.processInfo {
                    HStack(spacing: 5) {
                        Text(info.name)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(Color.green.opacity(0.9))

                        Text("\u{00B7}")
                            .foregroundColor(Color.secondary.opacity(0.5))

                        Text("PID \(info.pid)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("available")
                        .font(.system(size: 11))
                        .foregroundColor(Color.secondary.opacity(0.55))
                }
            }

            Spacer()

            // Action buttons on hover
            if isHovered && !isEditingLabel {
                HStack(spacing: 6) {
                    // Edit label
                    Button {
                        labelDraft = status.watchedPort.label
                        isEditingLabel = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help("Edit label")

                    // Open in browser (active ports only)
                    if status.isActive {
                        Button(action: { openInBrowser(port: status.port) }) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.system(size: 10, weight: .medium))
                                Text("Open")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.accentColor))
                        }
                        .buttonStyle(.plain)
                        .help("Open localhost:\(status.port) in browser")
                    }
                }
                .transition(.scale.combined(with: .opacity))
            } else if status.isActive && !isEditingLabel {
                Text("\u{25CF}")
                    .font(.system(size: 6))
                    .foregroundColor(Color.green.opacity(0.7))
                    .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(rowBg)
        )
        .help(isEditingLabel ? "" : tooltipText)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    private func saveLabel() {
        var updated = status.watchedPort
        updated.label = labelDraft.trimmingCharacters(in: .whitespaces)
        monitor.updatePort(updated)
        isEditingLabel = false
    }

    private var rowBg: Color {
        switch (status.isActive, isHovered) {
        case (true, true):   return Color.green.opacity(0.13)
        case (true, false):  return Color.green.opacity(0.07)
        case (false, true):  return Color.secondary.opacity(0.08)
        case (false, false): return Color.clear
        }
    }

    private var tooltipText: String {
        guard let info = status.processInfo else {
            return "Port \(status.port) is available"
        }

        let lines: [String?] = [
            "Process: \(info.name)",
            "PID: \(info.pid)",
            info.path.map { "Path: \($0)" },
            info.startTime.map { "Uptime: \(Self.formatUptime(since: $0))" },
            info.memoryBytes.map { "Memory: \(Self.formatBytes($0))" },
        ]
        return lines.compactMap { $0 }.joined(separator: "\n")
    }

    private static func formatUptime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours < 24 { return "\(hours)h \(remainingMinutes)m" }
        let days = hours / 24
        let remainingHours = hours % 24
        return "\(days)d \(remainingHours)h"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / (1024 * 1024)
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }

    private func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Bar Button Helper

struct BarButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(isHovered ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isHovered)
    }
}

// MARK: - Help View

struct HelpView: View {
    @Environment(\.dismiss) var dismiss

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App identity
            VStack(spacing: 6) {
                Image(systemName: "network")
                    .font(.system(size: 28, weight: .light))
                    .foregroundColor(.accentColor)
                Text("porto-listo")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                Text("v\(appVersion)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 4)

            Text("A menu bar utility that monitors your configured localhost ports and shows which are in use. Add or remove ports in Settings -- only the ports you choose are monitored.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Features
            VStack(alignment: .leading, spacing: 8) {
                featureRow(icon: "eye", text: "Watch individual ports or ranges")
                featureRow(icon: "gearshape", text: "See which process and PID owns each port")
                featureRow(icon: "globe", text: "Open active ports in your browser")
                featureRow(icon: "arrow.clockwise", text: "Auto-refreshes every few seconds")
            }
            .padding(.horizontal, 8)

            Spacer()

            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 300, height: 380)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Time Formatter

private let timeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.timeStyle = .medium
    f.dateStyle = .none
    return f
}()
