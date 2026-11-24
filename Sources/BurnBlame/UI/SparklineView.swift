import SwiftUI

/// High-performance Canvas sparkline with smooth area gradient and live trailing indicator.
public struct SparklineView: View {
    public let values: [Double]
    public let maxValue: Double
    public let accentColor: Color
    public var showLiveDot: Bool = true

    public init(
        values: [Double],
        maxValue: Double = 100.0,
        accentColor: Color,
        showLiveDot: Bool = true
    ) {
        self.values = values
        self.maxValue = max(1.0, maxValue)
        self.accentColor = accentColor
        self.showLiveDot = showLiveDot
    }

    public var body: some View {
        Canvas { context, size in
            guard values.count >= 2, size.width > 4, size.height > 4 else { return }

            let insetTop: CGFloat = 4
            let insetBottom: CGFloat = 2
            let drawableHeight = size.height - insetTop - insetBottom
            let stepX = size.width / CGFloat(values.count - 1)

            let points: [CGPoint] = values.enumerated().map { idx, val in
                let clamped = min(max(val, 0), maxValue)
                let normalized = CGFloat(clamped / maxValue)
                let x = CGFloat(idx) * stepX
                let y = insetTop + drawableHeight * (1.0 - normalized)
                return CGPoint(x: x, y: y)
            }

            // Smooth path using mid-point quadratic curves
            var linePath = Path()
            linePath.move(to: points[0])
            for i in 1..<points.count {
                let prev = points[i - 1]
                let curr = points[i]
                let mid = CGPoint(x: (prev.x + curr.x) / 2, y: (prev.y + curr.y) / 2)
                if i == 1 {
                    linePath.addLine(to: mid)
                } else {
                    linePath.addQuadCurve(to: mid, control: prev)
                }
                if i == points.count - 1 {
                    linePath.addLine(to: curr)
                }
            }

            // Area fill path
            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            fillPath.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            fillPath.closeSubpath()

            let gradient = Gradient(colors: [
                accentColor.opacity(0.32),
                accentColor.opacity(0.02)
            ])

            context.fill(
                fillPath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: insetTop),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            context.stroke(
                linePath,
                with: .color(accentColor.opacity(0.95)),
                style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
            )

            if showLiveDot, let last = points.last {
                let glowRect = CGRect(x: last.x - 4.5, y: last.y - 4.5, width: 9, height: 9)
                context.fill(Path(ellipseIn: glowRect), with: .color(accentColor.opacity(0.28)))
                let dotRect = CGRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)
                context.fill(Path(ellipseIn: dotRect), with: .color(accentColor))
            }
        }
    }
}

/// Compact capsule meter bar for per-process CPU usage (zero GeometryReader overhead).
public struct CPUMeterBar: View {
    public let cpuPercent: Double
    public let coreCount: Int

    public init(cpuPercent: Double, coreCount: Int) {
        self.cpuPercent = cpuPercent
        self.coreCount = max(1, coreCount)
    }

    private var fillFraction: CGFloat {
        // Scale: 100% (1 full core) fills ~83% of the bar, 120%+ fills 100%
        CGFloat(min(1.0, max(0.04, cpuPercent / 120.0)))
    }

    public var body: some View {
        let tint = Theme.color(forCPUPercent: cpuPercent)
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.08))
            Capsule()
                .fill(tint)
                .scaleEffect(x: fillFraction, y: 1.0, anchor: .leading)
        }
        .frame(height: 4)
    }
}
