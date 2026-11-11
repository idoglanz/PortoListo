import Foundation
import Combine
import Darwin

// MARK: - Models

struct WatchedPort: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var value: String       // "3000" or "3000-3010"
    var label: String

    var isRange: Bool { value.contains("-") }

    var ports: [Int] {
        if isRange {
            let parts = value.split(separator: "-")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2,
               let start = Int(parts[0]),
               let end = Int(parts[1]),
               start <= end {
                return Array(start...end)
            }
        }
        if let p = Int(value.trimmingCharacters(in: .whitespaces)) {
            return [p]
        }
        return []
    }

    // MARK: - Validation

    static let maxRangeSize = 100

    enum ValidationError: LocalizedError {
        case empty
        case invalidPort
        case invalidRange
        case rangeTooLarge(max: Int)

        var errorDescription: String? {
            switch self {
            case .empty: return "Port value cannot be empty"
            case .invalidPort: return "Invalid port — enter a number between 1 and 65535"
            case .invalidRange: return "Invalid range — use format 3000-3010 (max 65535)"
            case .rangeTooLarge(let max): return "Range too large — maximum \(max) ports allowed"
            }
        }
    }

    static func validate(_ value: String) -> ValidationError? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }

        if trimmed.contains("-") {
            let parts = trimmed.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  let start = Int(parts[0]),
                  let end = Int(parts[1]),
                  start > 0, end <= 65535,
                  start < end
            else { return .invalidRange }
            if (end - start + 1) > maxRangeSize { return .rangeTooLarge(max: maxRangeSize) }
        } else {
            guard let p = Int(trimmed), p > 0, p <= 65535 else { return .invalidPort }
        }
        return nil
    }
}

/// The process behind a listening port.
nonisolated struct ProcessInfo: Equatable {
    let name: String
    let pid: Int
    let path: String?
    let startTime: Date?
    let memoryBytes: UInt64?
    let workingDirectory: String?
    /// What is running, in a few words ("vite · resource-planning", "redis · level").
    let detail: String?
    /// An Apple system service or a regular app's helper port: not shown unless pinned.
    let isBackground: Bool
    /// Docker / OrbStack / Rancher: its ports are named after their containers.
    let isContainerRuntime: Bool

    func with(detail: String) -> ProcessInfo {
        ProcessInfo(name: name, pid: pid, path: path, startTime: startTime, memoryBytes: memoryBytes,
                    workingDirectory: workingDirectory, detail: detail,
                    isBackground: isBackground, isContainerRuntime: isContainerRuntime)
    }
}

struct PortStatus: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    /// The user's pinned entry covering this port; nil for a port found automatically.
    let watchedPort: WatchedPort?
    let processInfo: ProcessInfo?

    var isActive: Bool { processInfo != nil }
    var isPinned: Bool { watchedPort != nil }

    /// The user's own label when they set one, otherwise what we detected.
    var displayLabel: String {
        if let label = watchedPort?.label, !label.isEmpty { return label }
        return processInfo?.detail ?? ""
    }
}

// MARK: - Errors

enum PortMonitorError: LocalizedError {
    case processListFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .processListFailed(let code):
            return "Could not list processes: \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - Port Monitor

@MainActor
class PortMonitor: ObservableObject {
    /// Pinned ports (running or not) plus every other running server we discovered, by port.
    @Published private(set) var statuses: [PortStatus] = []
    /// Pinned ports: always listed, with the user's labels.
    @Published private(set) var watchedPorts: [WatchedPort] = [] {
        didSet { save() }
    }
    /// List running servers that aren't pinned.
    @Published var autoDiscover = true {
        didSet { saveDiscoverySettings(); rebuildStatuses() }
    }
    /// Discovered ports the user hid.
    @Published private(set) var hiddenPorts: Set<Int> = [] {
        didSet { saveDiscoverySettings(); rebuildStatuses() }
    }
    /// Process names the user hid every port of.
    @Published private(set) var hiddenProcesses: Set<String> = [] {
        didSet { saveDiscoverySettings(); rebuildStatuses() }
    }
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastError: String?
    @Published var isPopoverOpen: Bool = false {
        didSet {
            guard isPopoverOpen != oldValue else { return }
            startMonitoring()
        }
    }

    private var monitorTask: Task<Void, Never>?
    private var isLoading = false
    private var listening: [Int: ProcessInfo] = [:]

    /// The IANA dynamic range: ports the OS hands out on request, not ones you choose for a server.
    private static let firstDynamicPort = 49152

    private var refreshInterval: Duration {
        isPopoverOpen ? .seconds(5) : .seconds(60)
    }

    init() {
        load()
        startMonitoring()
    }

    deinit {
        monitorTask?.cancel()
    }

    // MARK: - Public API

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: refreshInterval)
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true

        do {
            listening = try await Task.detached(priority: .utility) {
                try ProcessInspector.listeningPorts()
            }.value
            lastError = nil
            rebuildStatuses()
            lastRefreshed = Date()
        } catch {
            lastError = error.localizedDescription
        }

        isRefreshing = false
    }

    func addPort(_ wp: WatchedPort) {
        watchedPorts.append(wp)
        rebuildStatuses()
        Task { await refresh() }
    }

    func removePort(withID id: UUID) {
        watchedPorts.removeAll { $0.id == id }
        rebuildStatuses()
        Task { await refresh() }
    }

    func updatePort(_ updated: WatchedPort) {
        guard let index = watchedPorts.firstIndex(where: { $0.id == updated.id }) else { return }
        watchedPorts[index] = updated
        rebuildStatuses()
        Task { await refresh() }
    }

    /// Keep a discovered port listed even when it stops, under `label`.
    func pin(port: Int, label: String) {
        hiddenPorts.remove(port)
        addPort(WatchedPort(value: String(port), label: label))
    }

    func hide(port: Int) { hiddenPorts.insert(port) }
    func unhide(port: Int) { hiddenPorts.remove(port) }
    func hide(processName: String) { hiddenProcesses.insert(processName) }
    func unhide(processName: String) { hiddenProcesses.remove(processName) }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Private

    /// Pinned ports first claim their port; every other running server is shown unless it is
    /// system/app noise, on a dynamic port, or hidden.
    private func rebuildStatuses() {
        guard !isLoading else { return }

        var rows: [Int: PortStatus] = [:]
        for wp in watchedPorts {
            for port in wp.ports where rows[port] == nil {
                rows[port] = PortStatus(port: port, watchedPort: wp, processInfo: listening[port])
            }
        }

        if autoDiscover {
            for (port, info) in listening where rows[port] == nil && shouldDiscover(port: port, info: info) {
                rows[port] = PortStatus(port: port, watchedPort: nil, processInfo: info)
            }
        }

        statuses = rows.values.sorted { $0.port < $1.port }
    }

    private func shouldDiscover(port: Int, info: ProcessInfo) -> Bool {
        if hiddenPorts.contains(port) || hiddenProcesses.contains(info.name) { return false }
        if port >= Self.firstDynamicPort { return false }
        return !info.isBackground
    }

    // MARK: - Persistence

    private static let storageKey = "portolisto.watchedPorts"
    private static let autoDiscoverKey = "portolisto.autoDiscover"
    private static let hiddenPortsKey = "portolisto.hiddenPorts"
    private static let hiddenProcessesKey = "portolisto.hiddenProcesses"

    /// Nothing pinned on first launch: running servers show up on their own.
    private static let defaultPorts: [WatchedPort] = []

    private func save() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(watchedPorts)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            lastError = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func saveDiscoverySettings() {
        guard !isLoading else { return }
        let defaults = UserDefaults.standard
        defaults.set(autoDiscover, forKey: Self.autoDiscoverKey)
        defaults.set(hiddenPorts.sorted(), forKey: Self.hiddenPortsKey)
        defaults.set(hiddenProcesses.sorted(), forKey: Self.hiddenProcessesKey)
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

        let defaults = UserDefaults.standard
        autoDiscover = defaults.object(forKey: Self.autoDiscoverKey) as? Bool ?? true
        hiddenPorts = Set(defaults.array(forKey: Self.hiddenPortsKey) as? [Int] ?? [])
        hiddenProcesses = Set(defaults.array(forKey: Self.hiddenProcessesKey) as? [String] ?? [])

        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else {
            // First launch — use defaults
            watchedPorts = Self.defaultPorts
            return
        }

        do {
            watchedPorts = try JSONDecoder().decode([WatchedPort].self, from: data)
        } catch {
            lastError = "Saved port data was corrupted. Defaults restored."
            watchedPorts = Self.defaultPorts
        }
    }
}
