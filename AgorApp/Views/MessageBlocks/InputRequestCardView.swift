import SwiftUI

struct InputRequestCardView: View {
    let content: InputRequestContent
    let isFirstPending: Bool
    var onSubmit: (([String: String]) -> Void)?

    @State private var selectedAnswers: [String: String] = [:]
    @State private var customText: String = ""

    var body: some View {
        if content.isResolved {
            resolvedView
        } else {
            pendingView
        }
    }

    // MARK: - Pending State

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .font(.body)
                    .foregroundStyle(.blue)

                Text("Input Request")
                    .font(.subheadline.weight(.semibold))
            }

            // Questions
            ForEach(Array(content.questions.enumerated()), id: \.offset) { index, question in
                QuestionView(
                    question: question,
                    questionIndex: index,
                    selectedAnswer: Binding(
                        get: { selectedAnswers["\(index)"] ?? "" },
                        set: { selectedAnswers["\(index)"] = $0 }
                    ),
                    isEnabled: isFirstPending
                )
            }

            // Submit
            if isFirstPending {
                Button("Submit") {
                    HapticFeedback.light()
                    onSubmit?(selectedAnswers)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!allQuestionsAnswered)
            }
        }
        .padding(12)
        .background(.blue.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.blue.opacity(isFirstPending ? 0.6 : 0.2), lineWidth: isFirstPending ? 2 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Resolved State

    private var resolvedView: some View {
        DisclosureGroup {
            if let answers = content.answers {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(answers.sorted(by: { $0.key < $1.key })), id: \.key) { key, value in
                        Text("\(key): \(value)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("✅")
                    .font(.caption)
                Text("Answered")
                    .font(.caption.weight(.medium))
                if let first = content.answers?.values.first {
                    Text(first)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var allQuestionsAnswered: Bool {
        for (index, _) in content.questions.enumerated() {
            if selectedAnswers["\(index)"]?.isEmpty ?? true {
                return false
            }
        }
        return true
    }
}

// MARK: - Question View

private struct QuestionView: View {
    let question: InputRequestQuestion
    let questionIndex: Int
    @Binding var selectedAnswer: String
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header chip
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.blue)
            }

            // Question text
            Text(question.question)
                .font(.subheadline)

            // Options
            ForEach(question.options) { option in
                Button {
                    guard isEnabled else { return }
                    selectedAnswer = option.label
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selectedAnswer == option.label
                            ? (question.multiSelect ? "checkmark.square.fill" : "circle.inset.filled")
                            : (question.multiSelect ? "square" : "circle"))
                            .foregroundStyle(selectedAnswer == option.label ? .blue : .secondary)
                            .font(.body)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            if !option.description.isEmpty {
                                Text(option.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
            }
        }
    }
}
