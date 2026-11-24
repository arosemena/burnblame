import Darwin
import Foundation

/// On-demand deep forensic inspector for a single process.
/// Only runs when the user clicks a process in the UI, keeping background monitoring lightweight.
public final class ProcessInspector: @unchecked Sendable {
    private struct LaunchPlistEntry {
        let label: String
        let plistPath: String
        let isDaemon: Bool
        let programPaths: [String]
    }

    private var cachedLaunchPlists: [LaunchPlistEntry]?

    public init() {}

    public func inspect(entry: ProcessEntry) -> ProcessInspection {
        let pid = entry.pid
        let execPath = entry.executablePath ?? ProcessSampler.executablePath(for: pid)
        let cwd = fetchWorkingDirectory(pid: pid)
        let args = fetchCommandLine(pid: pid)
        let chain = fetchParentChain(startingAt: entry.ppid)
        let username = fetchUsername(uid: entry.uid)
        let (fdCount, listeningPorts) = fetchSocketsAndFDCount(pid: pid)
        let (footprint, wakeups) = fetchRusageDetails(pid: pid)

        let origin = inferLaunchOrigin(
            entry: entry,
            execPath: execPath,
            cwd: cwd,
            parentChain: chain
        )

        return ProcessInspection(
            pid: pid,
            executablePath: execPath,
            workingDirectory: cwd,
            commandLine: args,
            parentChain: chain,
            username: username,
            launchOrigin: origin,
            openFileCount: fdCount,
            listeningPorts: listeningPorts,
            idleWakeups: wakeups,
            physicalFootprintBytes: footprint ?? entry.memoryBytes,
            inspectedAt: Date()
        )
    }

    // MARK: - Working Directory via PROC_PIDVNODEPATHINFO

    private func fetchWorkingDirectory(pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size)
        guard ret == size else { return nil }

        let path = withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cStr in
                String(cString: cStr)
            }
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Command Line Arguments via sysctl(KERN_PROCARGS2)

    private func fetchCommandLine(pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size: Int = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        // Add small headroom in case args grew slightly
        size += 256
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return []
        }

        let argc: Int32 = buffer.withUnsafeBytes { raw in
            raw.load(as: Int32.self)
        }
        guard argc > 0, argc < 4096 else { return [] }

        var offset = MemoryLayout<Int32>.size

        // Skip exec_path string
        while offset < size && buffer[offset] != 0 {
            offset += 1
        }
        // Skip null padding bytes between exec_path and argv[0]
        while offset < size && buffer[offset] == 0 {
            offset += 1
        }

        var args: [String] = []
        args.reserveCapacity(Int(argc))

        for _ in 0..<argc {
            guard offset < size else { break }
            let start = offset
            while offset < size && buffer[offset] != 0 {
                offset += 1
            }
            if offset > start {
                let slice = buffer[start..<offset]
                if let str = String(bytes: slice, encoding: .utf8) {
                    args.append(str)
                }
            }
            offset += 1 // skip null terminator
        }

        return args
    }

    // MARK: - Parent Process Ancestry Chain

    private func fetchParentChain(startingAt initialPPID: pid_t) -> [ProcessAncestor] {
        var chain: [ProcessAncestor] = []
        var visited = Set<pid_t>()
        var current = initialPPID
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)

        while current > 0 && !visited.contains(current) && chain.count < 16 {
            visited.insert(current)
            let ret = proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &bsd, bsdSize)
            if ret != bsdSize {
                if current == 1 {
                    chain.append(ProcessAncestor(pid: 1, name: "launchd", executablePath: "/sbin/launchd"))
                }
                break
            }

            let name = withUnsafePointer(to: bsd.pbi_name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(2 * MAXCOMLEN)) { cStr in
                    String(cString: cStr)
                }
            }
            let fallbackName = name.isEmpty ? withUnsafePointer(to: bsd.pbi_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { cStr in
                    String(cString: cStr)
                }
            } : name

            let execPath = ProcessSampler.executablePath(for: current)
            chain.append(ProcessAncestor(
                pid: current,
                name: fallbackName.isEmpty ? "pid \(current)" : fallbackName,
                executablePath: execPath
            ))

            if current == 1 { break }
            current = pid_t(bsd.pbi_ppid)
        }

        // Return root-first order (e.g. launchd -> Terminal -> zsh -> node)
        return chain.reversed()
    }

    // MARK: - Username

    private func fetchUsername(uid: uid_t) -> String {
        if let pw = getpwuid(uid), let namePtr = pw.pointee.pw_name {
            return String(cString: namePtr)
        }
        return uid == 0 ? "root" : "uid \(uid)"
    }

    // MARK: - Open File Descriptors & Listening Ports

    private func fetchSocketsAndFDCount(pid: pid_t) -> (Int, [String]) {
        let estimatedBytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimatedBytes > 0 else { return (0, []) }

        let fdStride = MemoryLayout<proc_fdinfo>.stride
        let capacity = Int(estimatedBytes) / fdStride + 16
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)

        let actualBytes = fds.withUnsafeMutableBufferPointer { buf in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buf.baseAddress, Int32(capacity * fdStride))
        }
        guard actualBytes > 0 else { return (0, []) }

        let count = Int(actualBytes) / fdStride
        var ports = Set<String>()
        var socketInfo = socket_fdinfo()
        let socketInfoSize = Int32(MemoryLayout<socket_fdinfo>.stride)

        for i in 0..<count {
            let fd = fds[i]
            if fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                let ret = proc_pidfdinfo(
                    pid,
                    fd.proc_fd,
                    PROC_PIDFDSOCKETINFO,
                    &socketInfo,
                    socketInfoSize
                )
                if ret == socketInfoSize {
                    let family = socketInfo.psi.soi_family
                    let kind = socketInfo.psi.soi_kind
                    if kind == SOCKINFO_TCP && (family == AF_INET || family == AF_INET6) {
                        let tcp = socketInfo.psi.soi_proto.pri_tcp
                        if tcp.tcpsi_state == TSI_S_LISTEN {
                            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
                            if port > 0 {
                                let host = formatLocalAddress(inInfo: tcp.tcpsi_ini, family: family)
                                ports.insert("\(host):\(port)")
                            }
                        }
                    }
                }
            }
        }

        return (count, ports.sorted())
    }

    private func formatLocalAddress(inInfo: in_sockinfo, family: Int32) -> String {
        var addrBuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if family == AF_INET {
            var addr = inInfo.insi_laddr.ina_46.i46a_addr4
            if inet_ntop(AF_INET, &addr, &addrBuf, socklen_t(INET_ADDRSTRLEN)) != nil {
                let str = addrBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                return str == "0.0.0.0" ? "*" : str
            }
        } else if family == AF_INET6 {
            var addr = inInfo.insi_laddr.ina_6
            if inet_ntop(AF_INET6, &addr, &addrBuf, socklen_t(INET6_ADDRSTRLEN)) != nil {
                let str = addrBuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                return str == "::" ? "*" : str
            }
        }
        return "*"
    }

    // MARK: - Rusage Details

    private func fetchRusageDetails(pid: pid_t) -> (UInt64?, UInt64) {
        var rusage = rusage_info_v4()
        let ret = withUnsafeMutablePointer(to: &rusage) { ptr -> Int32 in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rusagePtr in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rusagePtr)
            }
        }
        guard ret == 0 else { return (nil, 0) }
        return (rusage.ri_phys_footprint, rusage.ri_pkg_idle_wkups)
    }

    // MARK: - Launch Origin Inference

    private func inferLaunchOrigin(
        entry: ProcessEntry,
        execPath: String?,
        cwd: String?,
        parentChain: [ProcessAncestor]
    ) -> LaunchOrigin {
        // 1. Check if spawned from a terminal or shell
        let shellsAndTerminals: Set<String> = [
            "zsh", "bash", "sh", "fish", "tcsh", "nu", "tmux", "screen",
            "Terminal", "iTerm2", "Ghostty", "Warp", "WezTerm", "Alacritty", "kitty"
        ]
        if let shellAncestor = parentChain.reversed().first(where: { shellsAndTerminals.contains($0.name) }) {
            return .terminal(shell: shellAncestor.name, workingDir: cwd)
        }

        // 2. Check LaunchAgents / LaunchDaemons if directly under launchd
        if entry.ppid == 1, let execPath {
            if let match = matchLaunchPlist(executablePath: execPath) {
                return match.isDaemon
                    ? .launchDaemon(label: match.label, plistPath: match.plistPath)
                    : .launchAgent(label: match.label, plistPath: match.plistPath)
            }
        }

        // 3. Check if inside an .app bundle
        if let bundlePath = entry.bundlePath {
            let appName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
            return .application(name: appName, bundlePath: bundlePath)
        }

        // 4. Check non-launchd parent process
        if let directParent = parentChain.last, directParent.pid != 1 {
            return .parentProcess(name: directParent.name)
        }

        // 5. System binary under /System or /usr/libexec
        if let execPath,
           execPath.hasPrefix("/System/") || execPath.hasPrefix("/usr/libexec/") || execPath.hasPrefix("/usr/sbin/") {
            return .systemDaemon
        }

        return .unknown
    }

    private func matchLaunchPlist(executablePath: String) -> LaunchPlistEntry? {
        if cachedLaunchPlists == nil {
            cachedLaunchPlists = loadLaunchPlists()
        }
        return cachedLaunchPlists?.first { entry in
            entry.programPaths.contains { $0 == executablePath }
        }
    }

    private func loadLaunchPlists() -> [LaunchPlistEntry] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let directories: [(path: String, isDaemon: Bool)] = [
            ("\(home)/Library/LaunchAgents", false),
            ("/Library/LaunchAgents", false),
            ("/Library/LaunchDaemons", true)
        ]

        var entries: [LaunchPlistEntry] = []

        for (dir, isDaemon) in directories {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let fullPath = "\(dir)/\(file)"
                guard let data = fm.contents(atPath: fullPath),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                else { continue }

                let label = (plist["Label"] as? String) ?? (file as NSString).deletingPathExtension
                var paths: [String] = []
                if let prog = plist["Program"] as? String {
                    paths.append(prog)
                }
                if let progArgs = plist["ProgramArguments"] as? [String], let first = progArgs.first {
                    paths.append(first)
                }
                if !paths.isEmpty {
                    entries.append(LaunchPlistEntry(
                        label: label,
                        plistPath: fullPath,
                        isDaemon: isDaemon,
                        programPaths: paths
                    ))
                }
            }
        }

        return entries
    }
}
