//
//  SharedViews.swift
//  DriverStats
//
//  Created by Pierce Oxley on 7/6/26.
//

import Charts
import SwiftUI

// MARK: - Legacy components (kept while screens are being redesigned)

struct StatusRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
        .padding(.vertical, 2)
    }
}

struct SpeedChart: View {
    let speedsKph: [Double]
    private var decimated: [(index: Int, speed: Double)] {
        guard !speedsKph.isEmpty else { return [] }
        let step = max(1, speedsKph.count / 500)
        return speedsKph.indices.filter { $0 % step == 0 }.map { (index: $0, speed: speedsKph[$0]) }
    }
    private var yMax: Double { max(speedsKph.max() ?? 10, 10) * 1.15 }
    var body: some View {
        Chart(decimated, id: \.index) { point in
            AreaMark(x: .value("Time", point.index), y: .value("Speed", point.speed)).foregroundStyle(.blue.opacity(0.15))
            LineMark(x: .value("Time", point.index), y: .value("Speed", point.speed)).foregroundStyle(.blue).lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: 0...yMax).chartXAxis(.hidden).chartYAxisLabel("km/h", alignment: .trailing).frame(height: 110)
    }
}

struct ElevationChart: View {
    let altitudesM: [Double]
    private var decimated: [(index: Int, alt: Double)] {
        guard !altitudesM.isEmpty else { return [] }
        let step = max(1, altitudesM.count / 500)
        return altitudesM.indices.filter { $0 % step == 0 }.map { (index: $0, alt: altitudesM[$0]) }
    }
    private var yRange: ClosedRange<Double> {
        let mn = altitudesM.min() ?? 0; let mx = altitudesM.max() ?? 10
        let pad = max((mx - mn) * 0.15, 5); return (mn - pad)...(mx + pad)
    }
    var body: some View {
        Chart(decimated, id: \.index) { point in
            AreaMark(x: .value("Time", point.index), y: .value("Altitude (m)", point.alt)).foregroundStyle(.brown.opacity(0.15))
            LineMark(x: .value("Time", point.index), y: .value("Altitude (m)", point.alt)).foregroundStyle(.brown).lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: yRange).chartXAxis(.hidden).chartYAxisLabel("m", alignment: .trailing).frame(height: 80)
    }
}

struct SpeedLegendView: View {
    let maxSpeedMps: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speed color scale").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("0").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(colors: [.red, .orange, .yellow, .green],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8).clipShape(Capsule())
                Text(String(format: "%.0f km/h", maxSpeedMps * 3.6)).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - CardSection

struct CardSection<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    var innerPadding: CGFloat = 14
    let content: Content

    init(_ title: String? = nil, note: String? = nil, innerPadding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.title = title; self.note = note; self.innerPadding = innerPadding; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || note != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.footnote).fontWeight(.medium).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.3)
                    }
                    Spacer()
                    if let note {
                        Text(note).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 7)
            }
            content
                .padding(innerPadding)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

// MARK: - SectionHeader

struct SectionHeader: View {
    let title: String
    var note: String? = nil

    init(_ title: String, note: String? = nil) { self.title = title; self.note = note }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.footnote).fontWeight(.medium).textCase(.uppercase).foregroundStyle(.secondary).tracking(0.3)
            Spacer()
            if let note { Text(note).font(.system(.caption, design: .monospaced)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 16)
    }
}

// MARK: - Format helpers

func formatDuration(_ seconds: Double) -> String {
    let t = Int(seconds); let h = t / 3600, m = (t % 3600) / 60, s = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatDistance(_ meters: Double) -> String {
    meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
}

// MARK: - StatRow

struct StatRow: View {
    let label: String
    let value: String
    var si: String? = nil
    var isLast: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.body).foregroundStyle(Color(.label))
                Spacer()
                if let si {
                    Text(si).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).frame(minWidth: 80, alignment: .trailing)
                }
                Text(value).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 9)
            if !isLast { Divider() }
        }
    }
}

// MARK: - StatCell

struct StatCell: View {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String? = nil
    var accent: Bool = false
    var cardBackground: Color = Color(.secondarySystemGroupedBackground)

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 21, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(accent ? Color.accentColor : Color(.label))
                if let unit { Text(unit).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            }
            if let sub { Text(sub).font(.caption2).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Dial

/// Circular gauge. 270° arc from 7-o'clock (−135°) to 5-o'clock (+135°).
struct Dial: View {
    let value: Double
    let max: Double
    var unit: String = ""
    var label: String? = nil
    var size: CGFloat = 150
    var zone: Color = .accentColor
    var decimals: Int = 0
    var bigValue: Bool = false

    private static let designStart: Double = -135
    private static let sweep: Double = 270

    var body: some View {
        ZStack {
            Canvas { context, sz in
                let cx = sz.width / 2; let cy = sz.height / 2; let r = Swift.min(cx, cy) - 11
                let A0 = Self.designStart
                let frac = Swift.max(0.0, Swift.min(1.0, value / max))
                let aV = A0 + Self.sweep * frac

                func toPt(_ deg: Double, radius: CGFloat) -> CGPoint {
                    let rad = (deg - 90) * .pi / 180
                    return CGPoint(x: cx + radius * cos(rad), y: cy + radius * sin(rad))
                }

                var track = Path()
                track.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                             startAngle: .degrees(A0 - 90), endAngle: .degrees(A0 + Self.sweep - 90), clockwise: false)
                context.stroke(track, with: .color(Color(.systemFill)), style: StrokeStyle(lineWidth: 8, lineCap: .round))

                if frac > 0 {
                    var varc = Path()
                    varc.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                                startAngle: .degrees(A0 - 90), endAngle: .degrees(aV - 90), clockwise: false)
                    context.stroke(varc, with: .color(zone), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                }

                for i in 0...8 {
                    let a = A0 + Self.sweep * Double(i) / 8.0; let isMajor = i % 2 == 0
                    var tick = Path()
                    tick.move(to: toPt(a, radius: r + 3)); tick.addLine(to: toPt(a, radius: r - (isMajor ? 6 : 3)))
                    context.stroke(tick, with: .color(Color(.separator)),
                                   style: StrokeStyle(lineWidth: isMajor ? 1.4 : 1.0, lineCap: .round))
                }

                var ptr = Path()
                ptr.move(to: toPt(aV, radius: r + 1)); ptr.addLine(to: toPt(aV, radius: r - 14))
                context.stroke(ptr, with: .color(Color(.label)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            .frame(width: size, height: size)

            VStack(spacing: 6) {
                Text(String(format: "%.\(decimals)f", value))
                    .font(.system(size: bigValue ? 40 : 27, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if !unit.isEmpty {
                    Text(unit).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
                if let label {
                    Text(label).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.top, size * 0.08)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - GravityBubble

struct GravityBubble: View {
    var forward: Double = 0
    var lateral: Double = 0
    var gmax: Double = 0.8
    var size: CGFloat = 168
    var isStable: Bool = false
    var isFelt: Bool = false

    var body: some View {
        Canvas { context, sz in
            let r = sz.width / 2; let trackR = r - 12; let maxR = r - 16

            for (i, f) in zip(0..., [0.25, 0.5, 0.75, 1.0] as [Double]) {
                let rr = trackR * CGFloat(f)
                var ring = Path()
                ring.addEllipse(in: CGRect(x: r - rr, y: r - rr, width: rr * 2, height: rr * 2))
                context.stroke(ring, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1, dash: i < 3 ? [3, 4] : []))
            }

            var vl = Path(); vl.move(to: CGPoint(x: r, y: 6)); vl.addLine(to: CGPoint(x: r, y: sz.height - 6))
            var hl = Path(); hl.move(to: CGPoint(x: 6, y: r)); hl.addLine(to: CGPoint(x: sz.width - 6, y: r))
            context.stroke(vl, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1))
            context.stroke(hl, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1))

            let dotX = r + CGFloat(lateral / gmax) * maxR
            let dotY = r - CGFloat(forward / gmax) * maxR
            let dotColor = isStable ? Color.green : Color.accentColor
            let ch: CGFloat = 7

            var cH = Path(); cH.move(to: CGPoint(x: dotX - ch, y: dotY)); cH.addLine(to: CGPoint(x: dotX + ch, y: dotY))
            var cV = Path(); cV.move(to: CGPoint(x: dotX, y: dotY - ch)); cV.addLine(to: CGPoint(x: dotX, y: dotY + ch))
            context.stroke(cH, with: .color(dotColor), style: StrokeStyle(lineWidth: 1.2))
            context.stroke(cV, with: .color(dotColor), style: StrokeStyle(lineWidth: 1.2))

            let dotR: CGFloat = 7
            var dotPath = Path()
            dotPath.addEllipse(in: CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2))
            context.fill(dotPath, with: .color(dotColor.opacity(0.18)))
            context.stroke(dotPath, with: .color(dotColor), style: StrokeStyle(lineWidth: 1.8))
        }
        .overlay(alignment: .top)     { Text(isFelt ? "fwd" : "accel").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.top, 6) }
        .overlay(alignment: .bottom)  { Text(isFelt ? "back" : "brake").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.bottom, 6) }
        .overlay(alignment: .trailing){ Text("R").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.trailing, 4) }
        .overlay(alignment: .leading) { Text("L").font(.system(size: 9)).foregroundStyle(.tertiary).padding(.leading, 4) }
        .frame(width: size, height: size)
    }
}

// MARK: - GG Diagram

struct GGPoint {
    var lat: Double
    var fwd: Double
    var isPeak: Bool = false
}

struct GGDiagram: View {
    var points: [GGPoint] = []
    var gmax: Double = 1.0
    var size: CGFloat = 200
    var showEnvelope: Bool = false
    var showTrail: Bool = false
    var current: GGPoint? = nil
    var isFelt: Bool = false

    var body: some View {
        let hull = showEnvelope ? Self.convexHull(points) : []

        Canvas { context, sz in
            let r = sz.width / 2; let cm = r - 16

            func pt(_ lat: Double, _ fwd: Double) -> CGPoint {
                CGPoint(x: r + CGFloat(lat / gmax) * cm, y: r - CGFloat(fwd / gmax) * cm)
            }

            for f: Double in [0.25, 0.5, 0.75, 1.0] {
                let rr = cm * CGFloat(f)
                var ring = Path()
                ring.addEllipse(in: CGRect(x: r - rr, y: r - rr, width: rr * 2, height: rr * 2))
                context.stroke(ring, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1))
            }

            for f: Double in [0.5, 1.0] {
                let labelY = r - cm * CGFloat(f) + 10
                context.draw(Text(String(format: "%.1f", gmax * f)).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Color(.tertiaryLabel)),
                             at: CGPoint(x: r + 3, y: labelY), anchor: .leading)
            }

            var vl = Path(); vl.move(to: CGPoint(x: r, y: 6)); vl.addLine(to: CGPoint(x: r, y: sz.height - 6))
            var hl = Path(); hl.move(to: CGPoint(x: 6, y: r)); hl.addLine(to: CGPoint(x: sz.width - 6, y: r))
            context.stroke(vl, with: .color(Color(.separator).opacity(0.8)), style: StrokeStyle(lineWidth: 1))
            context.stroke(hl, with: .color(Color(.separator).opacity(0.8)), style: StrokeStyle(lineWidth: 1))

            if showEnvelope && hull.count > 2 {
                var hullPath = Path()
                let hpts = hull.map { pt($0.lat, $0.fwd) }
                hullPath.move(to: hpts[0])
                for p in hpts.dropFirst() { hullPath.addLine(to: p) }
                hullPath.closeSubpath()
                context.fill(hullPath, with: .color(Color.accentColor.opacity(0.08)))
                context.stroke(hullPath, with: .color(Color.accentColor.opacity(0.55)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }

            if showTrail && points.count > 1 {
                var trail = Path()
                let tpts = points.map { pt($0.lat, $0.fwd) }
                trail.move(to: tpts[0])
                for p in tpts.dropFirst() { trail.addLine(to: p) }
                context.stroke(trail, with: .color(Color.accentColor.opacity(0.35)), style: StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }

            // Render scatter — downsample visually if very large, but hull uses all points
            let renderPoints = (!showTrail && points.count > 2000)
                ? stride(from: 0, to: points.count, by: points.count / 2000).map { points[$0] }
                : points
            if !showTrail {
                for p in renderPoints {
                    let c = pt(p.lat, p.fwd)
                    let dotR: CGFloat = p.isPeak ? 3 : 1.5
                    var dot = Path()
                    dot.addEllipse(in: CGRect(x: c.x - dotR, y: c.y - dotR, width: dotR * 2, height: dotR * 2))
                    if p.isPeak {
                        context.fill(dot, with: .color(Color.accentColor))
                    } else {
                        let mag = min(1.0, (p.lat * p.lat + p.fwd * p.fwd).squareRoot() / gmax)
                        let dotColor: Color = mag > 0.6 ? .orange : mag > 0.3 ? Color.accentColor : Color(.tertiaryLabel)
                        context.fill(dot, with: .color(dotColor.opacity(0.45)))
                    }
                }
            }

            if let cur = current {
                let c = pt(cur.lat, cur.fwd)
                var outer = Path(); outer.addEllipse(in: CGRect(x: c.x - 6, y: c.y - 6, width: 12, height: 12))
                var inner = Path(); inner.addEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))
                context.fill(outer, with: .color(Color.accentColor.opacity(0.2)))
                context.stroke(outer, with: .color(Color.accentColor), style: StrokeStyle(lineWidth: 2))
                context.fill(inner, with: .color(Color.accentColor))
            }
        }
        .overlay(alignment: .top)     { Text(isFelt ? "fwd" : "accel").font(.system(size: 8.5)).foregroundStyle(.tertiary).padding(.top, 4) }
        .overlay(alignment: .bottom)  { Text(isFelt ? "back" : "brake").font(.system(size: 8.5)).foregroundStyle(.tertiary).padding(.bottom, 4) }
        .overlay(alignment: .trailing){ Text("right").font(.system(size: 8.5)).foregroundStyle(.tertiary).padding(.trailing, 4) }
        .overlay(alignment: .leading) { Text("left").font(.system(size: 8.5)).foregroundStyle(.tertiary).padding(.leading, 4) }
        .frame(width: size, height: size)
    }

    private static func convexHull(_ pts: [GGPoint]) -> [GGPoint] {
        guard pts.count >= 3 else { return pts }
        let sorted = pts.sorted { $0.lat != $1.lat ? $0.lat < $1.lat : $0.fwd < $1.fwd }
        func cross(_ o: GGPoint, _ a: GGPoint, _ b: GGPoint) -> Double {
            (a.lat - o.lat) * (b.fwd - o.fwd) - (a.fwd - o.fwd) * (b.lat - o.lat)
        }
        var lower: [GGPoint] = []
        for p in sorted { while lower.count >= 2 && cross(lower[lower.count-2], lower[lower.count-1], p) <= 0 { lower.removeLast() }; lower.append(p) }
        var upper: [GGPoint] = []
        for p in sorted.reversed() { while upper.count >= 2 && cross(upper[upper.count-2], upper[upper.count-1], p) <= 0 { upper.removeLast() }; upper.append(p) }
        lower.removeLast(); upper.removeLast()
        return lower + upper
    }
}

// MARK: - ScoreRing

struct ScoreRing: View {
    var value: Int = 84
    var label: String = ""
    var size: CGFloat = 64

    private var ringColor: Color { value >= 80 ? .green : value >= 60 ? .orange : .red }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color(.systemFill), lineWidth: 4.5)
                Circle()
                    .trim(from: 0, to: min(1, CGFloat(value) / 100))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: value)
                Text("\(value)")
                    .font(.system(size: size * 0.34, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            if !label.isEmpty { Text(label).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let data: [Double]
    var color: Color = .accentColor
    var showFill: Bool = true
    var height: CGFloat = 56
    var label: String? = nil
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if label != nil || unit != nil {
                HStack {
                    if let label { Text(label).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if let unit { Text(unit).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary) }
                }
            }
            Chart {
                ForEach(Array(data.enumerated()), id: \.offset) { i, v in
                    if showFill { AreaMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color.opacity(0.12)) }
                    LineMark(x: .value("i", i), y: .value("v", v)).foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.6))
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).frame(height: height)
        }
    }
}

// MARK: - AccelStrip

struct AccelStrip: View {
    let title: String
    let samples: [AccelerationSample]
    let value: KeyPath<AccelerationSample, Double>
    var color: Color = .accentColor
    var scale: Double = 1.0

    private var xDomain: ClosedRange<Double> {
        guard let last = samples.last else { return 0...15 }
        return max(0, last.elapsedSeconds - 15)...last.elapsedSeconds
    }

    private var yRange: Double {
        let maxAbs = samples.map { abs($0[keyPath: value]) }.max() ?? 0
        let raw = max(1.0, maxAbs * 1.2)
        return (raw / 0.5).rounded(.up) * 0.5
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "±%.1f g", yRange)).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
            }
            Chart {
                ForEach(samples) { sample in
                    LineMark(x: .value("t", sample.elapsedSeconds), y: .value("g", sample[keyPath: value] * scale))
                        .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.5))
                }
                RuleMark(y: .value("zero", 0)).foregroundStyle(Color(.separator)).lineStyle(StrokeStyle(dash: [3, 4]))
            }
            .chartXScale(domain: xDomain).chartYScale(domain: -yRange...yRange)
            .chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .clipped()
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - BarMeter

struct BarMeter: View {
    let label: String
    let value: Double
    let max: Double
    let display: String
    var color: Color = .accentColor
    var bidirectional: Bool = false

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(display).font(.system(.caption, design: .monospaced)).foregroundStyle(Color(.label))
            }
            Canvas { context, sz in
                let w = sz.width; let h = sz.height; let cr = h / 2
                context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: cr), with: .color(Color(.systemFill)))
                if bidirectional {
                    let frac = CGFloat(Swift.min(1, abs(value) / max))
                    let barW = w * frac / 2
                    let barX: CGFloat = value >= 0 ? w / 2 : w / 2 - barW
                    if barW > 0 { context.fill(Path(roundedRect: CGRect(x: barX, y: 0, width: barW, height: h), cornerRadius: cr), with: .color(color)) }
                    var cl = Path(); cl.move(to: CGPoint(x: w/2, y: 0)); cl.addLine(to: CGPoint(x: w/2, y: h))
                    context.stroke(cl, with: .color(Color(.separator)), style: StrokeStyle(lineWidth: 1))
                } else {
                    let frac = CGFloat(Swift.min(1, Swift.max(0, value / max)))
                    if frac > 0 { context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w * frac, height: h), cornerRadius: cr), with: .color(color)) }
                }
            }
            .frame(height: 6)
        }
        .padding(.bottom, 11)
    }
}

// MARK: - StatusLamp

enum LampState { case ok, warn, bad, off }

struct StatusLamp: View {
    let state: LampState
    let label: String
    var detail: String? = nil

    private var dotColor: Color {
        switch state {
        case .ok: return .green; case .warn: return .orange; case .bad: return .red; case .off: return Color(.tertiaryLabel)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(dotColor).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.body).foregroundStyle(Color(.label))
                if let detail { Text(detail).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - DriveStatPill

/// Icon + value label used in drive/trip history cards.
struct DriveStatPill: View {
    let systemImage: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}
