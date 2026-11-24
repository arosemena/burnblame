# BurnBlame

A lean, native macOS menu bar app for pinpointing **what made your MacBook heat up and spin up the fans**, inspecting *where* those processes came from, and taking immediate action.

## Features

- **Thermal-First Attribution (CPU + GPU + Disk I/O + Hardware Sensors)**
  - Reads real **CPU/GPU die temperatures (°C)**, **Fan RPM**, and **System Power (W)** natively via AppleSMC, plus **GPU utilization %** via IOKit `IOAccelerator` and macOS thermal pressure.
  - Ranks apps by **rolling heat burned** (1-minute & 5-minute CPU-seconds + Disk I/O energy) rather than noisy instantaneous spikes, so rows stay calm and stable.
  - Groups helpers & nested `.app` bundles under their parent app, retains **recently exited culprits**, freezes row order while hovering, and catches `root` / system processes (`WindowServer`, `mds_stores`, etc.) on demand.
  - Automatically logs **Heat Events** whenever fans spin up, die temp climbs, or sustained load occurs.
- **Feather-Light & Snappy**
  - Uses native Mach, `libproc`, `sysctl`, and IOKit syscalls with adaptive sampling (stretches to 15s background scans when closed & cool) and displays its own live CPU% & `ms/tick` overhead.
  - Borderless floating `NSPanel`, pre-rasterized 2× Retina `CGImage` icon cache, and `Equatable`-gated rows.
- **Forensic Process Inspector & Actions**
  - Click any process to inspect its **Launch Origin** (App Bundle, Terminal/Shell, or `LaunchAgent`/`LaunchDaemon` `.plist`), **Parent Ancestry Chain**, **Working Directory**, **Executable Path**, **Full Command Line**, and **Listening TCP Ports**.
  - Take action directly: **Pause / Resume** (`SIGSTOP`/`SIGCONT`), **Throttle** (`renice +15`), **Quit** (`SIGTERM`), **Force Quit** (`SIGKILL`), **Reveal in Finder**, or **Copy Diagnostics**.

## Build & Run

### Build `BurnBlame.app`
```bash
./scripts/build-app.sh
open dist/BurnBlame.app
```

### Run directly via SwiftPM
```bash
swift run
```

### Run Tests
```bash
swift test
```
