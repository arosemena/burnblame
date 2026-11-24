# MacWatcher

A lightweight, native macOS menu bar app for spotting high-CPU processes, inspecting *where* they came from and *why* they're running, and taking immediate action.

## Features

- **Feather-Light Adaptive Sampling**
  - Uses native Mach & BSD syscalls (`host_statistics`, `libproc`, `sysctl`, `proc_pid_rusage`) — zero `ps` or `top` subprocesses.
  - When the menu is **closed**, samples only system-wide CPU ticks every 3s (microseconds) and scans processes only on CPU spikes or periodically.
  - When the menu is **open**, switches to 1.5s live sampling with real-time sparklines.
  - Displays its own CPU usage in the footer.
- **Forensic Process Inspector (On-Demand)**
  - Click any process to inspect:
    - **Launch Origin**: App Bundle, Terminal/Shell session, LaunchAgent/LaunchDaemon (with clickable `.plist` reveal), or parent app.
    - **Parent Ancestry Chain**: e.g. `launchd → Terminal → zsh → npm → node`.
    - **Working Directory** (clickable to open in Finder) & **Executable Path** (Reveal in Finder).
    - **Full Command Line & Arguments** via `KERN_PROCARGS2` (one-click copy).
    - **Listening TCP Ports** (natively via `PROC_PIDFDSOCKETINFO`) to spot forgotten dev servers.
    - **Sustained High-CPU Detection** (flags runaway/hung processes vs brief spikes).
- **Direct Actions**
  - **Pause / Resume** (`SIGSTOP` / `SIGCONT`) — freeze a runaway process without losing its state while you investigate.
  - **Throttle** (`renice +15`) — lower scheduling priority so a build or script stops choking your Mac.
  - **Quit** (`SIGTERM`) & **Force Quit** (`SIGKILL` with two-step confirmation).
  - **Copy Diagnostics** to clipboard.

## Build & Run

### Run directly via SwiftPM
```bash
swift run
```

### Build a standalone `MacWatcher.app` bundle
```bash
chmod +x scripts/build-app.sh
./scripts/build-app.sh
open dist/MacWatcher.app
```

### Run Tests
```bash
swift test
```
