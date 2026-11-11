import Foundation
import Darwin

/// Everything PortoListo learns about the processes behind listening ports, read straight from
/// the kernel through libproc and sysctl. No subprocesses, no root.
///
/// All members are nonisolated and synchronous: call them from a background task.
nonisolated enum ProcessInspector {

    // MARK: - Listening sockets

    /// Every listening TCP port owned by the current user's processes, with what we know about
    /// the process behind it. When several sockets share a port (IPv4 + IPv6), the first wins.
    ///
    /// Walks each process's file descriptors (the same source `lsof` uses). PortoListo used to
    /// parse `netstat -anv -p tcp`, but since macOS 27 the kernel's TCP socket list
    /// (`net.inet.tcp.pcblist_n`) comes back empty for apps, so every port looked free.
    nonisolated static func listeningPorts() throws -> [Int: ProcessInfo] {
        var byPort: [Int: ProcessInfo] = [:]
        var described: [pid_t: ProcessInfo] = [:]
        var dockerPorts: [Int]?

        for (port, pid) in try listeningSockets() where !byPort.keys.contains(port) {
            let info = described[pid] ?? describe(pid: pid)
            described[pid] = info
            byPort[port] = info
            if info.isContainerRuntime { dockerPorts = (dockerPorts ?? []) + [port] }
        }

        // Ports published by Docker all belong to one backend process; name them after their container.
        if let dockerPorts {
            let containers = DockerContainers.publishedPorts()
            for port in dockerPorts {
                guard let label = containers[port], let info = byPort[port] else { continue }
                byPort[port] = info.with(detail: label)
            }
        }
        return byPort
    }

    /// (port, pid) for every listening TCP socket we are allowed to inspect.
    /// Processes owned by other users (root daemons) are skipped: proc_pidinfo fails for them.
    nonisolated static func listeningSockets() throws -> [(port: Int, pid: pid_t)] {
        let pidCount = proc_listallpids(nil, 0)
        guard pidCount > 0 else { throw PortMonitorError.processListFailed(errno: errno) }

        // Headroom for processes spawned between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(pidCount) + 128)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { throw PortMonitorError.processListFailed(errno: errno) }

        var sockets: [(port: Int, pid: pid_t)] = []
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.size)

        for pid in pids.prefix(Int(listed)) where pid > 0 {
            let fdBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard fdBytes > 0 else { continue }

            var fds = [proc_fdinfo](
                repeating: proc_fdinfo(),
                count: Int(fdBytes) / MemoryLayout<proc_fdinfo>.stride
            )
            let gotBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, fdBytes)
            guard gotBytes > 0 else { continue }

            for fd in fds.prefix(Int(gotBytes) / MemoryLayout<proc_fdinfo>.stride)
            where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketInfoSize) == socketInfoSize,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP)
                else { continue }

                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }

                // insi_lport holds the port in network byte order.
                let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
                if port > 0 { sockets.append((port, pid)) }
            }
        }
        return sockets
    }

    // MARK: - Describing a process

    nonisolated static func describe(pid: pid_t) -> ProcessInfo {
        let path = executablePath(pid: pid)
        let name = processName(pid: pid, path: path)
        let cwd = workingDirectory(pid: pid)
        let usage = resourceUsage(pid: pid)
        return ProcessInfo(
            name: name,
            pid: Int(pid),
            path: path,
            startTime: usage.startTime,
            memoryBytes: usage.memoryBytes,
            workingDirectory: cwd,
            detail: detail(name: name, arguments: arguments(pid: pid), cwd: cwd),
            isBackground: isBackground(path: path),
            isContainerRuntime: isContainerRuntime(path: path)
        )
    }

    /// What is running, in a few words: "vite · resource-planning", "manage.py · backend".
    /// nil when we know nothing better than the process name.
    nonisolated static func detail(name: String, arguments: [String], cwd: String?) -> String? {
        if name == "session-manager-plugin" { return "AWS SSM port forward" }

        var tool: String?
        var project = projectName(directory: cwd)

        if isInterpreter(name), let entry = entryPoint(arguments: arguments) {
            if entry.isModule {
                tool = entry.value                        // python -m uvicorn → "uvicorn"
            } else {
                let script = resolve(entry.value, relativeTo: cwd)
                if let range = script.range(of: "/node_modules/", options: .backwards) {
                    // node …/my-app/node_modules/.bin/vite → "vite", project "my-app"
                    tool = packageName(String(script[range.upperBound...]))
                    project = projectName(directory: String(script[..<range.lowerBound])) ?? project
                } else {
                    tool = (script as NSString).lastPathComponent
                }
            }
        }

        let parts = [tool, project].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Noise filtering

    /// Apple system services and the helper ports of ordinary GUI apps (Spotify, VS Code's
    /// Code Helper, AirPlay in ControlCenter…) — not something you started on purpose.
    nonisolated static func isBackground(path: String?) -> Bool {
        guard let path else { return false }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        if path.contains(".app/") {
            return !developerApps.contains { path.contains("/\($0)/") }
        }
        return false
    }

    private static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// App bundles whose ports ARE development servers. Python.app is where framework builds
    /// of Python (python.org, Homebrew, Xcode's python3) actually run from.
    private static let developerApps = [
        "Docker.app", "OrbStack.app", "Rancher Desktop.app", "Podman Desktop.app",
        "Postgres.app", "DBngin.app", "Ollama.app", "LM Studio.app", "Herd.app", "Python.app",
    ]

    private nonisolated static func isContainerRuntime(path: String?) -> Bool {
        guard let path else { return false }
        return ["/Docker.app/", "/OrbStack.app/", "/Rancher Desktop.app/"].contains { path.contains($0) }
    }

    // MARK: - Helpers

    private static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "java", "php", "perl"]

    private nonisolated static func isInterpreter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return interpreters.contains(lower) || lower.hasPrefix("python")
    }

    /// The script or module an interpreter was started with, skipping its own flags.
    private nonisolated static func entryPoint(arguments: [String]) -> (value: String, isModule: Bool)? {
        let flagsWithValue: Set<String> = ["-r", "--require", "--import", "--loader", "-W", "-X", "--env-file"]
        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-m", index + 1 < arguments.count { return (arguments[index + 1], true) }
            if arg == "-c" || arg == "-e" || arg == "--eval" { return nil }
            if flagsWithValue.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") { index += 1; continue }
            return (arg, false)
        }
        return nil
    }

    /// "…/.bin/vite" → "vite", "@nestjs/cli/bin/nest.js" → "@nestjs/cli", "vite/bin/vite.js" → "vite"
    private nonisolated static func packageName(_ pathInsideNodeModules: String) -> String? {
        var parts = pathInsideNodeModules.split(separator: "/").map(String.init)
        if parts.first == ".bin" { parts.removeFirst() }
        guard let first = parts.first else { return nil }
        if first.hasPrefix("@"), parts.count > 1 { return "\(first)/\(parts[1])" }
        return first
    }

    private nonisolated static func resolve(_ path: String, relativeTo cwd: String?) -> String {
        let base = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) }
        return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path
    }

    /// The folder a process works in, as a project name. nil for "/" and the home folder,
    /// which say nothing about the project.
    private nonisolated static func projectName(directory: String?) -> String? {
        guard let directory, !directory.isEmpty else { return nil }
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        if trimmed.isEmpty || trimmed == NSHomeDirectory() { return nil }
        return (trimmed as NSString).lastPathComponent
    }

    private nonisolated static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Full executable name ("com.docker.backend", "Code Helper"), falling back to the kernel's
    /// process name. netstat used to truncate these to 16 characters.
    private nonisolated static func processName(pid: pid_t, path: String?) -> String {
        if let path, !path.isEmpty {
            return (path as NSString).lastPathComponent
        }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : "pid \(pid)"
    }

    private nonisolated static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// argv of a process, via sysctl KERN_PROCARGS2:
    /// [argc: Int32][exec path\0][padding \0…][argv[0]\0][argv[1]\0]…[env…]
    private nonisolated static func arguments(pid: pid_t) -> [String] {
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) == 0, argMax > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        var size = buffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec path
        while index < size, buffer[index] == 0 { index += 1 }   // padding

        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    private nonisolated static func resourceUsage(pid: pid_t) -> (startTime: Date?, memoryBytes: UInt64?) {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let startTime: Date? = (sysctl(&mib, 4, &info, &size, nil, 0) == 0 && size > 0) ? {
            let tv = info.kp_proc.p_starttime
            return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        }() : nil

        var taskInfo = proc_taskinfo()
        let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let memoryBytes: UInt64? = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, taskInfoSize) > 0
            ? taskInfo.pti_resident_size : nil

        return (startTime, memoryBytes)
    }
}

// MARK: - Docker

/// Names Docker's published ports after their containers by asking the Docker Engine API over
/// its unix socket. Docker Desktop publishes every container port from one backend process,
/// so without this they would all just read "com.docker.backend".
nonisolated enum DockerContainers {
    private static let socketPaths = [
        NSHomeDirectory() + "/.docker/run/docker.sock",
        NSHomeDirectory() + "/.orbstack/run/docker.sock",
        NSHomeDirectory() + "/.rd/docker.sock",
        "/var/run/docker.sock",
    ]

    private struct Container: Decodable {
        struct Port: Decodable {
            let PublicPort: Int?
            let `Type`: String?
        }
        let Names: [String]?
        let Ports: [Port]?
        let Labels: [String: String]?
    }

    /// Published host port → "service · compose-project" (or the container name). Empty when
    /// Docker isn't reachable; this is a nicety and never an error.
    nonisolated static func publishedPorts() -> [Int: String] {
        for path in socketPaths where FileManager.default.fileExists(atPath: path) {
            guard let body = get("/containers/json", socketPath: path),
                  let containers = try? JSONDecoder().decode([Container].self, from: body)
            else { continue }

            var result: [Int: String] = [:]
            for container in containers {
                let label = label(for: container)
                for port in container.Ports ?? [] where port.Type == "tcp" {
                    if let published = port.PublicPort { result[published] = label }
                }
            }
            return result
        }
        return [:]
    }

    private nonisolated static func label(for container: Container) -> String {
        if let service = container.Labels?["com.docker.compose.service"] {
            if let project = container.Labels?["com.docker.compose.project"] {
                return "\(service) · \(project)"
            }
            return service
        }
        let name = container.Names?.first ?? "container"
        return name.hasPrefix("/") ? String(name.dropFirst()) : name
    }

    /// Minimal HTTP/1.0 GET over a unix socket (HTTP/1.0 so the reply is never chunked and the
    /// server closes when done). Times out after a second either way.
    private nonisolated static func get(_ requestPath: String, socketPath: String) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let request = Array("GET \(requestPath) HTTP/1.0\r\nHost: docker\r\n\r\n".utf8)
        guard write(fd, request, request.count) == request.count else { return nil }

        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while response.count < 8 * 1024 * 1024 {
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { break }
            response.append(contentsOf: chunk[0..<count])
        }

        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)),
              let statusLine = String(data: response[..<headerEnd.lowerBound], encoding: .utf8)?
                .split(separator: "\r\n").first,
              statusLine.contains(" 200 ")
        else { return nil }
        return response[headerEnd.upperBound...]
    }
}
