import Foundation
import Combine

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

struct ProcessInfo: Equatable {
    let name: String
    let pid: Int
    let path: String?
    let startTime: Date?
    let memoryBytes: UInt64?
}

struct PortStatus: Identifiable, Equatable {
    var id: Int { port }
    let port: Int
    let watchedPort: WatchedPort
    let processInfo: ProcessInfo?

    var isActive: Bool { processInfo != nil }
}

// MARK: - Errors

enum PortMonitorError: LocalizedError {
    case netstatFailed(exitCode: Int32, stderr: String)
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .netstatFailed(let code, let stderr):
            return "netstat failed (exit \(code)): \(stderr.prefix(200))"
        case .decodeFailed:
            return "Failed to decode netstat output"
        }
    }
}

// MARK: - Port Monitor

@MainActor
class PortMonitor: ObservableObject {
    @Published private(set) var statuses: [PortStatus] = []
    @Published private(set) var watchedPorts: [WatchedPort] = [] {
        didSet { save() }
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
            let listening = try await fetchPortsViaNetstat()
            lastError = nil

            statuses = watchedPorts.flatMap { wp in
                wp.ports.map { port in
                    PortStatus(port: port, watchedPort: wp, processInfo: listening[port])
                }
            }
            .sorted { $0.port < $1.port }

            lastRefreshed = Date()
        } catch {
            lastError = error.localizedDescription
        }

        isRefreshing = false
    }

    func addPort(_ wp: WatchedPort) {
        watchedPorts.append(wp)
        Task { await refresh() }
    }

    func removePort(withID id: UUID) {
        watchedPorts.removeAll { $0.id == id }
        Task { await refresh() }
    }

    func updatePort(_ updated: WatchedPort) {
        guard let index = watchedPorts.firstIndex(where: { $0.id == updated.id }) else { return }
        watchedPorts[index] = updated
        Task { await refresh() }
    }

    func dismissError() {
        lastError = nil
    }

    // MARK: - Private

    /// Enrich a PID with executable path, start time, and memory usage via Darwin syscalls.
    /// Cheap: 1-2 syscalls, no external processes. Returns nil fields on failure (e.g. other user's process).
    private nonisolated static func enrichProcess(pid: Int32) -> (path: String?, startTime: Date?, memoryBytes: UInt64?) {
        // Executable path via proc_pidpath
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(MAXPATHLEN))
        let path: String? = pathLen > 0 ? String(cString: pathBuffer) : nil

        // Start time + memory via sysctl KERN_PROC_PID
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let sysctlResult = sysctl(&mib, 4, &info, &size, nil, 0)

        let startTime: Date? = (sysctlResult == 0 && size > 0) ? {
            let tv = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        }() : nil

        // Resident memory via proc_pidinfo PROC_PIDTASKINFO
        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let taskResult = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize)
        let memoryBytes: UInt64? = taskResult > 0 ? taskInfo.pti_resident_size : nil

        return (path, startTime, memoryBytes)
    }

    private func fetchPortsViaNetstat() async throws -> [Int: ProcessInfo] {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
            process.arguments = ["-anv", "-p", "tcp"]

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            // Sequential reads are safe here: netstat output is well under the 64KB pipe buffer
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let stderrStr = String(data: stderrData, encoding: .utf8) ?? "unknown error"
                throw PortMonitorError.netstatFailed(
                    exitCode: process.terminationStatus,
                    stderr: stderrStr
                )
            }

            guard let output = String(data: data, encoding: .utf8) else {
                throw PortMonitorError.decodeFailed
            }

            var result: [Int: ProcessInfo] = [:]

            // netstat -anv columns:
            // [0] Proto [1] Recv-Q [2] Send-Q [3] Local [4] Foreign [5] State
            // [6..9] rwhi/shiwat [10] processname:pid [11] state
            for line in output.components(separatedBy: "\n") {
                guard !line.isEmpty,
                      !line.hasPrefix("Active"),
                      !line.hasPrefix("Proto") else { continue }

                let cols = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

                guard cols.count >= 6,
                      cols[0] == "tcp4" || cols[0] == "tcp46" || cols[0] == "tcp6",
                      cols[5] == "LISTEN" else { continue }

                // Local address format: "*.3000", "127.0.0.1.3000", "[::1].8080", etc.
                let localAddr = cols[3]

                let portStr: String
                if localAddr.starts(with: "*.") {
                    portStr = String(localAddr.dropFirst(2))
                } else if localAddr.starts(with: "[") {
                    if let closeBracket = localAddr.lastIndex(of: "]"),
                       let dot = localAddr[closeBracket...].firstIndex(of: ".") {
                        portStr = String(localAddr[localAddr.index(after: dot)...])
                    } else {
                        continue
                    }
                } else if let lastDot = localAddr.lastIndex(of: ".") {
                    portStr = String(localAddr[localAddr.index(after: lastDot)...])
                } else {
                    continue
                }

                guard let port = Int(portStr) else { continue }

                guard cols.count > 10 else { continue }
                let processColumn = cols[10]
                guard let colonIndex = processColumn.lastIndex(of: ":") else { continue }
                let name = String(processColumn[..<colonIndex])
                guard let pid = Int(String(processColumn[processColumn.index(after: colonIndex)...])),
                      pid > 0 else { continue }

                let enriched = PortMonitor.enrichProcess(pid: Int32(pid))
                result[port] = ProcessInfo(
                    name: name,
                    pid: pid,
                    path: enriched.path,
                    startTime: enriched.startTime,
                    memoryBytes: enriched.memoryBytes
                )
            }

            return result
        }.value
    }

    // MARK: - Persistence

    private static let storageKey = "portolisto.watchedPorts"

    private static let defaultPorts: [WatchedPort] = [
        WatchedPort(value: "3000", label: "React / Next.js"),
        WatchedPort(value: "5173", label: "Vite"),
        WatchedPort(value: "8080", label: "Backend"),
        WatchedPort(value: "27017", label: "MongoDB"),
        WatchedPort(value: "5432", label: "Postgres"),
        WatchedPort(value: "6379", label: "Redis"),
    ]

    private func save() {
        guard !isLoading else { return }
        do {
            let data = try JSONEncoder().encode(watchedPorts)
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        } catch {
            lastError = "Failed to save settings: \(error.localizedDescription)"
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }

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
