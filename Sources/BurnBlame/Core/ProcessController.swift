import AppKit
import Darwin
import Foundation

/// Executes user actions on inspected processes (terminate, force quit, pause/resume, throttle, reveal, copy).
@MainActor
public enum ProcessController {
    public static func terminate(pid: pid_t) -> Result<Void, ProcessActionError> {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if app.terminate() {
                return .success(())
            }
        }
        return sendSignal(SIGTERM, to: pid)
    }

    public static func forceQuit(pid: pid_t) -> Result<Void, ProcessActionError> {
        if let app = NSRunningApplication(processIdentifier: pid) {
            if app.forceTerminate() {
                return .success(())
            }
        }
        return sendSignal(SIGKILL, to: pid)
    }

    public static func pause(pid: pid_t) -> Result<Void, ProcessActionError> {
        sendSignal(SIGSTOP, to: pid)
    }

    public static func resume(pid: pid_t) -> Result<Void, ProcessActionError> {
        sendSignal(SIGCONT, to: pid)
    }

    public static func throttle(pid: pid_t, niceValue: Int32 = 15) -> Result<Void, ProcessActionError> {
        let ret = setpriority(PRIO_PROCESS, id_t(pid), niceValue)
        if ret == 0 {
            return .success(())
        }
        return mapErrno(errno, action: "throttle")
    }

    public static func revealInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func openFolder(path: String) {
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    public static func copyDiagnostics(entry: ProcessEntry, inspection: ProcessInspection?) {
        var lines: [String] = [
            "Process: \(entry.name) (PID \(entry.pid))",
            "CPU: \(String(format: "%.1f%%", entry.cpuPercent)) (Peak: \(String(format: "%.1f%%", entry.peakCPUPercent)))",
            "Memory: \(ByteCountFormatter.string(fromByteCount: Int64(entry.memoryBytes), countStyle: .memory))",
            "State: \(entry.state.rawValue) | Threads: \(entry.threadCount) | Nice: \(entry.niceValue)"
        ]

        if let inspection {
            lines.append("User: \(inspection.username)")
            lines.append("Origin: \(inspection.launchOrigin.title)")
            if !inspection.parentChain.isEmpty {
                let chainStr = inspection.parentChain.map { "\($0.name) (\($0.pid))" }.joined(separator: " → ")
                lines.append("Ancestry: \(chainStr)")
            }
            if let cwd = inspection.workingDirectory {
                lines.append("Working Dir: \(cwd)")
            }
            if let path = inspection.executablePath {
                lines.append("Executable: \(path)")
            }
            lines.append("Command: \(inspection.formattedCommand)")
            if !inspection.listeningPorts.isEmpty {
                lines.append("Listening Ports: \(inspection.listeningPorts.joined(separator: ", "))")
            }
        }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }

    private static func sendSignal(_ signal: Int32, to pid: pid_t) -> Result<Void, ProcessActionError> {
        let ret = Darwin.kill(pid, signal)
        if ret == 0 {
            return .success(())
        }
        return mapErrno(errno, action: "signal")
    }

    private static func mapErrno(_ code: Int32, action: String) -> Result<Void, ProcessActionError> {
        switch code {
        case EPERM:
            return .failure(.permissionDenied("Permission denied — this process is owned by another user or protected by macOS."))
        case ESRCH:
            return .failure(.processNotFound)
        default:
            let msg = String(cString: strerror(code))
            return .failure(.failed("Could not \(action) process: \(msg)"))
        }
    }
}
