import SwiftUI

struct AgentIcon: View {
    let agenticTool: AgenticToolName
    var size: CGFloat = 20

    var body: some View {
        switch agenticTool {
        case .claudeCode, .claudeCodeCli:
            ClaudeLogo()
                .frame(width: size, height: size)
        case .gemini:
            GeminiLogo()
                .frame(width: size, height: size)
        case .opencode:
            OpenCodeLogo(size: size)
                .frame(width: size, height: size)
        default:
            Image(systemName: iconName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(iconColor)
        }
    }

    private var iconName: String {
        switch agenticTool {
        case .claudeCode, .claudeCodeCli: "star.fill"
        case .codex: "cube"
        case .gemini: "diamond"
        case .opencode: "chevron.left.forwardslash.chevron.right"
        case .copilot: "person.2.fill"
        case .unknown: "questionmark.circle"
        }
    }

    private var iconColor: Color {
        switch agenticTool {
        case .claudeCode, .claudeCodeCli: .orange
        case .codex: .green
        case .gemini: .blue
        case .opencode: .purple
        case .copilot: .indigo
        case .unknown: .gray
        }
    }
}

// MARK: - Claude (Anthropic) starburst

/// Anthropic's Claude mark: an organic starburst of tapered rays in terracotta.
private struct ClaudeLogo: View {
    var body: some View {
        ClaudeStarburst()
            .fill(Color(red: 0.85, green: 0.47, blue: 0.34)) // #D97757
    }
}

private struct ClaudeStarburst: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let rayCount = 11
        // Slightly irregular ray lengths give the organic hand-drawn feel of the mark
        let lengths: [CGFloat] = [1.0, 0.82, 0.95, 0.78, 1.0, 0.85, 0.92, 0.8, 0.97, 0.84, 0.9]

        for i in 0..<rayCount {
            let angle = (CGFloat(i) / CGFloat(rayCount)) * 2 * .pi - .pi / 2
            let rayLength = outer * lengths[i % lengths.count]
            let halfWidth: CGFloat = .pi / CGFloat(rayCount) * 0.55

            let tip = CGPoint(
                x: center.x + cos(angle) * rayLength,
                y: center.y + sin(angle) * rayLength
            )
            let baseRadius = outer * 0.12
            let left = CGPoint(
                x: center.x + cos(angle - halfWidth) * baseRadius,
                y: center.y + sin(angle - halfWidth) * baseRadius
            )
            let right = CGPoint(
                x: center.x + cos(angle + halfWidth) * baseRadius,
                y: center.y + sin(angle + halfWidth) * baseRadius
            )

            path.move(to: left)
            path.addLine(to: tip)
            path.addLine(to: right)
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Gemini four-point sparkle

/// Google Gemini mark: a concave four-point star with the blue→purple gradient.
private struct GeminiLogo: View {
    var body: some View {
        GeminiSparkle()
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.26, green: 0.52, blue: 0.96), // #4285F4
                        Color(red: 0.61, green: 0.45, blue: 0.80)  // #9B72CB
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }
}

private struct GeminiSparkle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        let top = CGPoint(x: c.x, y: c.y - r)
        let rightP = CGPoint(x: c.x + r, y: c.y)
        let bottom = CGPoint(x: c.x, y: c.y + r)
        let leftP = CGPoint(x: c.x - r, y: c.y)

        // Concave edges curving through points near the center
        path.move(to: top)
        path.addQuadCurve(to: rightP, control: c)
        path.addQuadCurve(to: bottom, control: c)
        path.addQuadCurve(to: leftP, control: c)
        path.addQuadCurve(to: top, control: c)
        path.closeSubpath()
        return path
    }
}

// MARK: - OpenCode terminal mark

/// OpenCode mark: a dark rounded terminal square with a monospace prompt.
private struct OpenCodeLogo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color(white: 0.12))
            Text(">_")
                .font(.system(size: size * 0.45, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .offset(y: -size * 0.02)
        }
    }
}
