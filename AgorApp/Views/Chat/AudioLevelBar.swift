import SwiftUI

struct AudioLevelBar: View {
    let audioLevel: Float
    let threshold: Float
    let isRecording: Bool

    private let historyCount = 50
    private let maxScale: Float = 0.15

    @State private var history: [Float] = Array(repeating: 0, count: 50)

    var body: some View {
        Canvas { context, size in
            let barW = size.width / CGFloat(historyCount)

            for (i, level) in history.enumerated() {
                let normalized = CGFloat(sqrt(min(1.0, level / maxScale)))
                let barH = max(2, normalized * size.height)
                let rect = CGRect(
                    x: CGFloat(i) * barW,
                    y: size.height - barH,
                    width: max(1, barW - 1),
                    height: barH
                )
                let aboveThreshold = level > threshold
                let color: Color = aboveThreshold
                    ? (isRecording ? .red : .blue)
                    : .secondary.opacity(0.3)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }

            // Dashed threshold line
            let threshY = size.height * (1 - CGFloat(sqrt(min(1.0, threshold / maxScale))))
            var line = Path()
            line.move(to: CGPoint(x: 0, y: threshY))
            line.addLine(to: CGPoint(x: size.width, y: threshY))
            context.stroke(
                line,
                with: .color(.blue.opacity(0.4)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
        }
        .onChange(of: audioLevel) { _, newLevel in
            history.removeFirst()
            history.append(newLevel)
        }
    }
}
