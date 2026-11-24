#!/usr/bin/env swift
import AppKit
import SwiftUI

// Generates 3 pixel-exact 2880x1800 opaque sRGB PNG screenshots for Mac App Store Connect.
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dist/appstore-screenshots"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// MARK: - Shared Styling

struct MarketingCanvas<Content: View>: View {
    let headline: String
    let subheadline: String
    let pills: [(icon: String, text: String)]
    let accent: Color
    let menuBarText: String
    let menuBarIcon: String
    @ViewBuilder let panelContent: () -> Content

    var body: some View {
        ZStack {
            // Deep macOS obsidian-to-ember ambient mesh background
            LinearGradient(
                colors: [
                    Color(red: 0.06, green: 0.065, blue: 0.095),
                    Color(red: 0.09, green: 0.075, blue: 0.115),
                    Color(red: 0.045, green: 0.05, blue: 0.075)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Subtle warm radial glow behind the BurnBlame panel
            RadialGradient(
                colors: [accent.opacity(0.28), accent.opacity(0.06), .clear],
                center: UnitPoint(x: 0.72, y: 0.50),
                startRadius: 20,
                endRadius: 520
            )

            // Top macOS menu bar strip
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "apple.logo")
                        .font(.system(size: 13, weight: .semibold))
                    Text("BurnBlame")
                        .font(.system(size: 12.5, weight: .bold))
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: menuBarIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accent)
                        Text(menuBarText)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(accent)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12)))

                    Image(systemName: "wifi")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.8))
                    Image(systemName: "battery.75percent")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Mon 9:41 PM")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .frame(height: 30)
                .background(Color.black.opacity(0.45))

                Spacer()
            }

            // Main 2-column hero composition
            HStack(alignment: .center, spacing: 64) {
                // Left: Apple-style product copy
                VStack(alignment: .leading, spacing: 22) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.18, green: 0.18, blue: 0.23), Color(red: 0.08, green: 0.08, blue: 0.11)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 42, height: 42)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                )
                            Image(systemName: "flame.fill")
                                .font(.system(size: 21, weight: .bold))
                                .foregroundStyle(
                                    LinearGradient(colors: [.yellow, .orange, .red], startPoint: .top, endPoint: .bottom)
                                )
                        }
                        Text("BurnBlame")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                    }

                    Text(headline)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(subheadline)
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 11) {
                        ForEach(Array(pills.enumerated()), id: \.offset) { _, pill in
                            HStack(spacing: 10) {
                                Image(systemName: pill.icon)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(accent)
                                    .frame(width: 24)
                                Text(pill.text)
                                    .font(.system(size: 15.5, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.88))
                            }
                        }
                    }
                    .padding(.top, 6)
                }
                .frame(width: 540, alignment: .leading)

                // Right: Authentic BurnBlame floating panel
                panelContent()
                    .frame(width: 416, height: 560)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(red: 0.11, green: 0.115, blue: 0.135))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.55), radius: 36, y: 18)
                    .scaleEffect(1.18)
            }
            .padding(.top, 26)
        }
        .frame(width: 1440, height: 900)
        .environment(\.colorScheme, .dark)
    }
}

struct MiniSparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count >= 2 else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: CGFloat(i) * stepX, y: size.height * (1.0 - CGFloat(min(100, max(0, v)) / 100.0)) * 0.85 + 4)
            }
            var line = Path()
            line.move(to: pts[0])
            for i in 1..<pts.count {
                let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
                if i == 1 { line.addLine(to: mid) } else { line.addQuadCurve(to: mid, control: pts[i - 1]) }
                if i == pts.count - 1 { line.addLine(to: pts[i]) }
            }
            var fill = line
            fill.addLine(to: CGPoint(x: pts.last!.x, y: size.height))
            fill.addLine(to: CGPoint(x: pts.first!.x, y: size.height))
            fill.closeSubpath()
            ctx.fill(fill, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0.02)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            if let last = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(color))
            }
        }
    }
}

// MARK: - Slide 1: Thermal & Heat Overview

struct Slide1Panel: View {
    let rows: [(icon: String, iconColor: Color, name: String, count: String?, badge: (String, Color)?, sub: String, share: String, frac: Double, barColor: Color)] = [
        ("chevron.left.forwardslash.chevron.right", .orange, "swift-frontend", "8", ("+4 exited", .orange), "42s CPU · now 184% · 1.4 GB", "38%", 0.38, .red),
        ("globe", .cyan, "Google Chrome", "14", nil, "26s CPU · now 48.2% · 2.1 GB", "24%", 0.24, .orange),
        ("terminal.fill", .teal, "node", "3", ("DISK", .teal), "15s CPU · 184 MB I/O · 412 MB", "16%", 0.16, .cyan),
        ("shippingbox.fill", .indigo, "Docker Desktop", "5", nil, "11s CPU · now 22.4% · 1.8 GB", "11%", 0.11, .cyan),
        ("message.fill", .green, "Slack", "4", nil, "6.2s CPU · now 8.1% · 540 MB", "6%", 0.06, .green)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Hero Header
            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                Image(systemName: "thermometer.high")
                                    .font(.system(size: 10.5, weight: .bold))
                                Text("Hot")
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.red.opacity(0.2)))
                            .foregroundStyle(.red)

                            HStack(spacing: 2.5) {
                                Image(systemName: "bolt.fill").font(.system(size: 9))
                                Text("34.2W").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            }
                            .foregroundStyle(.orange)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("58%")
                                    .font(.system(size: 26, weight: .bold, design: .rounded))
                                    .foregroundStyle(.red)
                                Text("CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 3) {
                                Text("32%")
                                    .font(.system(size: 19, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.85))
                                Text("GPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Spacer()

                    MiniSparkline(values: [18, 22, 20, 34, 48, 52, 46, 61, 58, 64, 55, 59, 62, 58], color: .orange)
                        .frame(width: 150, height: 50)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                }

                HStack(spacing: 6) {
                    chip("thermometer.medium", "CPU 90°C", .red)
                    chip("square.stack.3d.up.fill", "GPU 78°C", .orange)
                    chip("fanblades.fill", "2640 RPM", .orange)
                    Spacer()
                    Text("1m avg 41%").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                }
            }
            .padding(14)

            Divider().opacity(0.3)

            // Tabs + Search
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    tab("1m Heat", selected: true)
                    tab("5m Heat", selected: false)
                    tab("Heat Log  2", selected: false)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Filter by app, helper, or PID…").font(.system(size: 11.5)).foregroundStyle(.secondary.opacity(0.7))
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            HStack {
                Text("HEAT CULPRITS · LAST 1M").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                Text("% of heat").font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 5)

            VStack(spacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(row.iconColor.opacity(0.16)).frame(width: 28, height: 28)
                            Image(systemName: row.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(row.iconColor)
                        }
                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack(spacing: 5) {
                                Text(row.name).font(.system(size: 12.5, weight: .semibold))
                                if let c = row.count {
                                    Text(c).font(.system(size: 8.5, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.white.opacity(0.1))).foregroundStyle(.secondary)
                                }
                                if let b = row.badge {
                                    Text(b.0).font(.system(size: 8.5, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(b.1.opacity(0.18))).foregroundStyle(b.1)
                                }
                            }
                            Text(row.sub).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3.5) {
                            Text(row.share).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(row.barColor)
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule().fill(row.barColor).scaleEffect(x: row.frac, y: 1, anchor: .leading)
                            }
                            .frame(width: 50, height: 4.5)
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary.opacity(0.5))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            Divider().opacity(0.3)

            // Footer
            HStack {
                Circle().fill(.green).frame(width: 6.5, height: 6.5)
                Text("BurnBlame: 0.2% · 4.1ms/tick").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "pause.fill").font(.system(size: 10.5)).frame(width: 24, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                Image(systemName: "slider.horizontal.3").font(.system(size: 10.5)).frame(width: 24, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
                Image(systemName: "power").font(.system(size: 10.5)).frame(width: 24, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.07)))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    func chip(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 3.5) {
            Image(systemName: icon).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(color)
        }
        .padding(.horizontal, 6.5).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    func tab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.blue.opacity(0.24) : Color.white.opacity(0.05)))
            .foregroundStyle(selected ? Color.blue : Color.secondary)
    }
}

// MARK: - Slide 2: Forensic Process Inspector

struct Slide2Panel: View {
    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10.5, weight: .semibold))
                    Text("Back").font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
                Spacer()
                Text("PID 48219").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "doc.on.doc").font(.system(size: 11)).frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08)))
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            Divider().opacity(0.3)

            VStack(alignment: .leading, spacing: 10) {
                // Telemetry Card
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.18)).frame(width: 34, height: 34)
                            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 16, weight: .bold)).foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("node").font(.system(size: 14, weight: .bold))
                            HStack(spacing: 6) {
                                Text("Running").font(.system(size: 9.5, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)
                                Text("rob · Up 3h 18m").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text("142%").font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                            Text("~1.4 cores").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }

                    MiniSparkline(values: [12, 18, 45, 82, 95, 91, 98, 94, 96, 99, 95, 97], color: .red)
                        .frame(height: 36)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.04)))

                    HStack(spacing: 7) {
                        stat("Peak CPU", "168%")
                        stat("Memory", "412 MB")
                        stat("Threads", "19")
                        stat("Nice", "0")
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.05)))

                // Forensics Card
                VStack(alignment: .leading, spacing: 8) {
                    Label("Where It Came From", systemImage: "magnifyingglass.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold))

                    HStack(spacing: 7) {
                        Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(.blue)
                            .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.16)))
                        Text("Terminal / zsh").font(.system(size: 11.5, weight: .semibold))
                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("LAUNCH CHAIN").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            crumb("launchd")
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                            crumb("Ghostty")
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                            crumb("zsh")
                            Image(systemName: "arrow.right").font(.system(size: 8)).foregroundStyle(.secondary)
                            Text("node").font(.system(size: 10, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2.5).background(RoundedRectangle(cornerRadius: 5).fill(Color.blue.opacity(0.24))).foregroundStyle(.blue)
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("WORKING DIRECTORY").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                            Spacer()
                            Text("Open").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                        }
                        Text("~/dev/analytics-api").font(.system(size: 10.5, design: .monospaced))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("LAUNCH COMMAND").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary)
                        Text("node ./dist/worker.js --watch --concurrency=8")
                            .font(.system(size: 10, design: .monospaced))
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.28)))
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "network").font(.system(size: 10.5)).foregroundStyle(.teal)
                        Text("127.0.0.1:3000").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 2.5).background(Capsule().fill(Color.teal.opacity(0.18))).foregroundStyle(.teal)
                        Text("*:9229").font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7).padding(.vertical, 2.5).background(Capsule().fill(Color.teal.opacity(0.18))).foregroundStyle(.teal)
                    }
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.05)))
            }
            .padding(12)

            Spacer()
            Divider().opacity(0.3)

            // Action Bar
            HStack(spacing: 7) {
                actionBtn("Pause", "pause.fill", .purple)
                actionBtn("Throttle", "tortoise.fill", .orange)
                actionBtn("Quit", "xmark.circle", .white)
                actionBtn("Kill", "bolt.slash.fill", .red)
            }
            .padding(11)
        }
    }

    func stat(_ label: String, _ val: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(val).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
    }

    func crumb(_ name: String) -> some View {
        Text(name).font(.system(size: 10, weight: .medium)).padding(.horizontal, 6).padding(.vertical, 2.5).background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
    }

    func actionBtn(_ title: String, _ icon: String, _ color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7.5)
            .background(RoundedRectangle(cornerRadius: 7).fill(color.opacity(color == .white ? 0.12 : 0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - Slide 3: Heat Log Timeline

struct Slide3Panel: View {
    var body: some View {
        VStack(spacing: 0) {
            // Compact Header
            VStack(spacing: 9) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "thermometer.low").font(.system(size: 10.5, weight: .bold))
                            Text("Cool").font(.system(size: 10.5, weight: .bold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.18))).foregroundStyle(.green)

                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("11%").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(.green)
                            Text("CPU · 4% GPU · 8.4W").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    MiniSparkline(values: [68, 72, 65, 42, 24, 16, 12, 10, 11, 9, 11], color: .green)
                        .frame(width: 140, height: 46)
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
                }
            }
            .padding(14)

            Divider().opacity(0.3)

            // Tabs
            HStack(spacing: 5) {
                tab("1m Heat", selected: false)
                tab("5m Heat", selected: false)
                tab("Heat Log  3", selected: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)

            // Event Cards
            VStack(spacing: 9) {
                eventCard(
                    time: "9:38 PM",
                    dur: "2m 14s",
                    temp: "92°C",
                    rpm: "3120 RPM",
                    watts: "39W",
                    reason: "Fans spun up to 3120 RPM",
                    culprits: [("swift-frontend", "68s", "52%"), ("Google Chrome", "29s", "22%"), ("node", "14s", "11%")]
                )
                eventCard(
                    time: "8:52 PM",
                    dur: "1m 05s",
                    temp: "86°C",
                    rpm: "2240 RPM",
                    watts: "31W",
                    reason: "CPU die reached 86°C",
                    culprits: [("Docker Desktop", "44s", "61%"), ("mds_stores", "18s", "25%")]
                )
            }
            .padding(.horizontal, 12)

            Spacer()
            Divider().opacity(0.3)

            HStack {
                Circle().fill(.green).frame(width: 6.5, height: 6.5)
                Text("BurnBlame: 0.1% · 1.8ms/tick").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text("15s idle cadence").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
    }

    func tab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 11, weight: selected ? .semibold : .medium))
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.blue.opacity(0.24) : Color.white.opacity(0.05)))
            .foregroundStyle(selected ? Color.blue : Color.secondary)
    }

    func eventCard(time: String, dur: String, temp: String, rpm: String, watts: String, reason: String, culprits: [(String, String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").font(.system(size: 11)).foregroundStyle(.red)
                Text(time).font(.system(size: 11.5, weight: .bold, design: .monospaced))
                Text("· \(dur)").font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                Text(temp).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.red)
                Text(rpm).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text(watts).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text(reason).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text("TOP HEAT ORIGINATORS").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.secondary.opacity(0.7))
            ForEach(Array(culprits.enumerated()), id: \.offset) { _, c in
                HStack {
                    Text(c.0).font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(c.1).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    Text(c.2).font(.system(size: 10.5, weight: .bold, design: .monospaced)).foregroundStyle(.orange).frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, 8).padding(.vertical, 4.5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75))
    }
}

// MARK: - Render Helper (2880x1800 opaque sRGB PNG — zero alpha for App Store Connect)

@MainActor
func renderSlide<V: View>(_ view: V, to filename: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2.0 // 1440x900 @2x = 2880x1800
    guard let cgImage = renderer.cgImage else {
        fatalError("Failed to render \(filename)")
    }

    // Re-draw into opaque RGB bitmap (no alpha channel, required by App Store Connect)
    let w = 2880
    let h = 1800
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else {
        fatalError("Failed to create RGB context")
    }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let opaqueCG = ctx.makeImage() else { fatalError("makeImage failed") }

    let rep = NSBitmapImageRep(cgImage: opaqueCG)
    let pngData = rep.representation(using: .png, properties: [:])!
    let path = "\(outDir)/\(filename)"
    try pngData.write(to: URL(fileURLWithPath: path))
    print("Wrote \(path) (\(w)x\(h), \(pngData.count / 1024) KB)")
}

MainActor.assumeIsolated {
    try! renderSlide(
        MarketingCanvas(
            headline: "Know what made\nyour fans spin up.",
            subheadline: "Rolling 1m & 5m heat attribution ranks apps by real energy burned — not noisy 1-second CPU spikes.",
            pills: [
                ("thermometer.high", "Live CPU, GPU, die temps, Fan RPM & Watts"),
                ("square.stack.3d.up.fill", "Groups app helpers into one calm, hover-pinned list"),
                ("bolt.fill", "Feather-light native Mach & IOKit engine")
            ],
            accent: .orange,
            menuBarText: "58%",
            menuBarIcon: "flame.fill"
        ) { Slide1Panel() },
        to: "01-heat-overview.png"
    )

    try! renderSlide(
        MarketingCanvas(
            headline: "Trace where every\nprocess came from.",
            subheadline: "Click any process to inspect its launch ancestry, working folder, command arguments, and open ports.",
            pills: [
                ("arrow.branch", "Full parent chain back to launchd & LaunchAgents"),
                ("network", "Native listening TCP port & folder inspection"),
                ("pause.circle.fill", "Pause, Throttle, Quit, or Force Quit in one click")
            ],
            accent: .red,
            menuBarText: "44%",
            menuBarIcon: "thermometer.high"
        ) { Slide2Panel() },
        to: "02-process-inspector.png"
    )

    try! renderSlide(
        MarketingCanvas(
            headline: "Catch heat spikes —\neven after they end.",
            subheadline: "BurnBlame automatically logs thermal jumps and retains recently exited culprits so nothing slips away.",
            pills: [
                ("clock.arrow.circlepath", "Automatic Heat Log with peak °C, RPM & culprits"),
                ("checkmark.seal.fill", "100% local — zero network calls or analytics"),
                ("leaf.fill", "Adaptive 15s idle cadence keeps overhead tiny")
            ],
            accent: .green,
            menuBarText: "11%",
            menuBarIcon: "thermometer.low"
        ) { Slide3Panel() },
        to: "03-heat-log.png"
    )
}
